package main

import (
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"sync"
	"time"
)

// randomHex 返回 n 字节的随机十六进制串（2n 个字符）。
//
// 失败时直接 panic：crypto/rand 失败说明系统熵源坏了，
// 此时"生成一个可能重复的 ID"比"立刻停下"危险得多（重复 ID 会静默覆盖别人的问题）。
func randomHex(n int) string {
	buf := make([]byte, n)
	if _, err := rand.Read(buf); err != nil {
		panic("crypto/rand 不可用: " + err.Error())
	}
	return hex.EncodeToString(buf)
}

// Store 是问题列表的持久化载体：内存里一份 + JSON 文件一份。
//
// 并发模型：一把 RWMutex 保护整份切片。数据量是"几条到几百条"，
// 换成分片锁或数据库只会增加出错面；读多写少的场景下这点锁竞争可忽略。
//
// 持久化策略：**每次写操作后整份落盘**（先写 .tmp 再 rename）。
// rename 在同一文件系统内是原子的——这保证"进程被 kill 时文件不会只写了一半"，
// 而那正是"重启后数据还在"这条要求最容易翻车的地方。
type Store struct {
	mu     sync.RWMutex
	path   string
	issues []Issue
}

// NewStore 打开（或创建）一份数据文件。
//
// 保证：文件存在且是合法 JSON 时，历史数据被读进内存；文件不存在时按空列表启动。
// 不保证：并发多进程写同一个文件——**本 Store 假设单写者**（同一目录只被一个进程打开）。
// 临时文件名带 pid + 纳秒，降低踩踏概率，但不等于支持多写者。
// 重要：**文件损坏或为空时返回错误而不是静默重建空库**——静默清空会让"数据丢了"
// 看起来像"本来就没有"，评审时无法察觉。要恢复就人工确认后删掉该文件。
func NewStore(path string) (*Store, error) {
	s := &Store{path: path, issues: []Issue{}}
	raw, err := os.ReadFile(path)
	if errors.Is(err, os.ErrNotExist) {
		return s, nil
	}
	if err != nil {
		return nil, err
	}
	if len(raw) == 0 {
		// 我们的写入路径永远不会产生空文件（写 tmp → rename，目标要么旧要么新）。
		// 出现空文件说明被外部截断/磁盘问题，此时继续跑会把空列表当成事实写回去，
		// 等于把"数据丢了"永久固化。
		return nil, errors.New("数据文件存在但为空（可能被截断）：为避免覆盖历史数据，拒绝启动")
	}
	if err := json.Unmarshal(raw, &s.issues); err != nil {
		return nil, errors.New("数据文件不是合法 JSON（为避免覆盖历史数据，拒绝启动）: " + err.Error())
	}
	// 防御：历史文件里若缺 status/priority，补成合法值，避免前端渲染出空白。
	for i := range s.issues {
		if !ValidStatus(s.issues[i].Status) {
			s.issues[i].Status = StatusOpen
		}
		if !ValidPriority(s.issues[i].Priority) {
			s.issues[i].Priority = PriorityMedium
		}
	}
	return s, nil
}

// Create 校验并保存一条新问题，返回落盘后的完整对象。
func (s *Store) Create(in Issue, now time.Time) (Issue, error) {
	if err := in.Validate(); err != nil {
		return Issue{}, err
	}
	stamp := now.UTC().Format(time.RFC3339)
	in.ID = NewID(now)
	in.CreatedAt = stamp
	in.UpdatedAt = stamp

	s.mu.Lock()
	defer s.mu.Unlock()
	s.issues = append(s.issues, in)
	if err := s.flushLocked(); err != nil {
		// 落盘失败必须回滚内存，否则会出现"接口返回成功但重启后丢了"的假成功。
		s.issues = s.issues[:len(s.issues)-1]
		return Issue{}, err
	}
	return in, nil
}

// List 返回按创建时间倒序（新的在前）的副本。
//
// 返回副本而不是内部切片：调用方（handler 序列化时）可能并发遍历，
// 直接暴露内部切片会让"读着读着被 append 扩容"变成数据竞争。
func (s *Store) List() []Issue {
	s.mu.RLock()
	defer s.mu.RUnlock()
	out := make([]Issue, len(s.issues))
	copy(out, s.issues)
	sort.SliceStable(out, func(i, j int) bool {
		if out[i].CreatedAt != out[j].CreatedAt {
			return out[i].CreatedAt > out[j].CreatedAt
		}
		return out[i].ID > out[j].ID
	})
	return out
}

// UpdateStatus 修改一条问题的状态。返回更新后的对象。
//
// 保证：id 不存在返回 errNotFound；status 非法返回 *FieldError（两者让 handler 分别给 404/400）。
// 保证：updatedAt 一定前移，createdAt 永不变（"修改状态"不该改创建时间）。
func (s *Store) UpdateStatus(id string, status Status, now time.Time) (Issue, error) {
	if !ValidStatus(status) {
		return Issue{}, &FieldError{
			Field:   "status",
			Code:    "status_invalid",
			Message: "status 必须是 open/in_progress/resolved，收到 " + string(status),
		}
	}

	s.mu.Lock()
	defer s.mu.Unlock()
	for i := range s.issues {
		if s.issues[i].ID != id {
			continue
		}
		prev := s.issues[i]
		s.issues[i].Status = status
		s.issues[i].UpdatedAt = now.UTC().Format(time.RFC3339)
		if err := s.flushLocked(); err != nil {
			s.issues[i] = prev // 与 Create 同理：落盘失败就回滚，不做"假成功"
			return Issue{}, err
		}
		return s.issues[i], nil
	}
	return Issue{}, errNotFound
}

// flushLocked 把整份数据原子写入磁盘。调用方必须已持有写锁（函数名里的 Locked 就是提醒）。
//
// 为什么不是 `os.WriteFile(tmp) + os.Rename` 就完事：
// rename 只保证"目录项切换"是原子的，**不保证 tmp 的内容已经落盘**。
// 断电/内核崩溃后可能出现"目标文件存在但内容为 0 或只有半截"——
// 而这份文件是唯一的数据源，那种损坏等于全量丢失。
// 所以顺序是：写 tmp → `f.Sync()` 刷数据 → close → rename → 刷父目录项。
// （Windows 上对目录做 Sync 会失败，那里是尽力而为；失败不阻塞主流程，见 syncDir。）
func (s *Store) flushLocked() error {
	raw, err := json.MarshalIndent(s.issues, "", "  ")
	if err != nil {
		return err
	}
	if dir := filepath.Dir(s.path); dir != "." {
		if err := os.MkdirAll(dir, 0o755); err != nil {
			return err
		}
	}

	// tmp 名字带 pid + 纳秒：同一目录被两个进程打开时不会互相踩同一个临时文件
	// （Store 本身仍是"单写者"假设，见类型注释——但至少不会静默覆盖对方还没 rename 的内容）。
	tmp := fmt.Sprintf("%s.%d.%d.tmp", s.path, os.Getpid(), time.Now().UnixNano())
	f, err := os.OpenFile(tmp, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0o644)
	if err != nil {
		return err
	}
	if _, err := f.Write(raw); err != nil {
		f.Close()
		os.Remove(tmp)
		return err
	}
	if err := f.Sync(); err != nil {
		f.Close()
		os.Remove(tmp)
		return err
	}
	if err := f.Close(); err != nil {
		os.Remove(tmp)
		return err
	}
	if err := os.Rename(tmp, s.path); err != nil {
		os.Remove(tmp)
		return err
	}
	syncDir(filepath.Dir(s.path))
	return nil
}

// syncDir 尽力把"目录项变更"刷到磁盘。
//
// 为什么允许失败：Windows 不支持以目录句柄做 fsync（会返回错误），
// 而"目录项可能没落盘"在这个原型里只影响断电场景的极端情况。
// 选择"尽力而为 + 不阻塞"，而不是"失败就当写入失败"——后者会让服务在 Windows 上完全不可用。
// 这不是隐藏缺陷：它写进了 README 的"已知问题"。
func syncDir(dir string) {
	d, err := os.Open(dir)
	if err != nil {
		return
	}
	defer d.Close()
	_ = d.Sync()
}
