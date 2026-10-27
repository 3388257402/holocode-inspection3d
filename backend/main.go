package main

import (
	"context"
	"errors"
	"flag"
	"log"
	"net"
	"net/http"
	"os"
	"os/signal"
	"path/filepath"
	"syscall"
	"time"
)

// 这个文件只做一件事：把 store + server 拼起来，并保证能优雅退出。
//
// 为什么默认监听 0.0.0.0 而不是 127.0.0.1：
// Unity 真机在同一个 Wi-Fi 下通过 `http://<电脑局域网IP>:8080` 访问；
// 只听本地回环时，手机会得到"连接被拒绝"，而这个现象很容易被误判成"防火墙/端口错"。
func main() {
	addr := flag.String("addr", ":8080", "监听地址，默认 :8080（所有网卡）")
	dataFile := flag.String("data", "data/issues.json", "数据文件路径（JSON 持久化）")
	flag.Parse()

	// 把数据路径解析成绝对路径**再**打印与使用：
	// 相对路径是相对"启动时的工作目录"的，同一个二进制在不同目录启动会静默读写两份不同数据，
	// 表现为"重启后数据不见了"。日志里给绝对路径，排查才有据可查。
	absData, err := filepath.Abs(*dataFile)
	if err != nil {
		log.Fatalf("解析数据文件路径失败: %v", err)
	}

	store, err := NewStore(absData)
	if err != nil {
		log.Fatalf("打开数据文件失败（%s）: %v", absData, err)
	}

	srv := &http.Server{
		Addr:              *addr,
		Handler:           NewServer(store),
		ReadHeaderTimeout: 10 * time.Second,
		// 补上读写超时：每个写请求都要持锁把整份数据落盘，
		// 一个"发得很慢"的客户端会长期占着连接，把优雅退出的 5 秒窗口吃光。
		ReadTimeout:  30 * time.Second,
		WriteTimeout: 30 * time.Second,
		IdleTimeout:  60 * time.Second,
	}

	// 信号注册放在主 goroutine、且在起服务之前：
	// 如果放在子 goroutine 里，注册完成前收到的 Ctrl+C 会走默认动作直接杀进程，跳过 Shutdown。
	//
	// **只能有一个 goroutine 读这个 channel。** 两个 goroutine 各持一个 `<-sig` 时，
	// Go 会在多个等待者里随机选一个唤醒——第一次 Ctrl+C 就可能被"立即退出"那条抢到，
	// 优雅关闭根本没发生，日志还会把它误报成"第二次信号"。
	// **设计决定：关闭过程不可中断。** 第一次信号后进入最多 5 秒的排空窗口；
	// 缓冲为 1，窗口内再按 Ctrl+C 只会被丢弃（不改变行为）。
	// 为什么不做"第二次信号强制退出"：那与"把在途写请求写完"直接冲突，
	// 而这个服务只有一个写者、一次落盘只有几毫秒——为省几秒多一条竞态路径不划算。
	// 代价写在 README 的"已知问题"里，而不是留一个"注册了却没人接收"的信号通道。
	sig := make(chan os.Signal, 1)
	signal.Notify(sig, os.Interrupt, syscall.SIGTERM)
	defer signal.Stop(sig)

	shutdownDone := make(chan struct{})
	// 关闭结果通过 channel 传回主 goroutine：**退出码要反映"有没有干净关闭"**，
	// 而不是反映"按了几次 Ctrl+C"。被强制 Close 掉的在途请求可能没落盘，
	// 那条路径必须以非零码退出，否则脚本/CI 会把"疑似丢写"当成成功。
	closeErr := make(chan error, 1)
	go func() {
		defer close(shutdownDone)
		<-sig // 第一次：优雅关闭
		log.Println("收到退出信号，正在关闭（最多等 5 秒，期间请不要重复中断）…")
		ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		if err := srv.Shutdown(ctx); err != nil {
			log.Printf("优雅关闭超时，强制关闭剩余连接（在途请求可能没有完成落盘）: %v", err)
			if cerr := srv.Close(); cerr != nil {
				log.Printf("强制关闭时又出错: %v", cerr)
			}
			closeErr <- err
			return
		}
		closeErr <- nil
	}()

	// 打印一个**能直接复制到浏览器/Unity** 的地址：默认 addr 是 ":8080"，
	// 直接拼会得到 `http://:8080`（主机为空），对人不可用。
	host, port, err := net.SplitHostPort(*addr)
	if err != nil || host == "" || host == "0.0.0.0" || host == "::" {
		host = "localhost"
	}
	log.Printf("巡检后端已启动 http://%s:%s （手机用电脑局域网 IP 替换 localhost），数据文件 %s",
		host, port, absData)
	if err := srv.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
		log.Fatalf("服务启动失败: %v", err)
	}
	<-shutdownDone
	if err := <-closeErr; err != nil {
		// 非干净关闭：有在途请求被硬断，可能没落盘。用非零码让调用方看得见。
		log.Println("退出码 1：关闭不干净，可能有请求未完成落盘")
		os.Exit(1)
	}
}
