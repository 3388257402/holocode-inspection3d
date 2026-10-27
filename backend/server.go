package main

import (
	"encoding/json"
	"errors"
	"log"
	"net/http"
	"strings"
	"time"
)

// Server 把 Store 与 HTTP 路由绑在一起。
//
// 为什么把 handler 做成方法而不是全局函数：单测要能造一个"独立的服务器 + 独立的数据文件"，
// 全局变量会让测试之间互相污染，最后只能靠"跑一遍全绿的顺序"糊过去。
type Server struct {
	store *Store
	mux   *http.ServeMux
	now   func() time.Time // 注入时钟，测试里可固定时间，断言 createdAt 才有确定性
}

// NewServer 组装路由。
func NewServer(store *Store) *Server {
	s := &Server{store: store, now: time.Now, mux: http.NewServeMux()}

	// Go 1.22+ 的方法 + 路径模式：省掉手写 method 判断，也让"路由写错"在启动期就暴露。
	s.mux.HandleFunc("GET /healthz", s.handleHealth)
	s.mux.HandleFunc("GET /api/issues", s.handleList)
	s.mux.HandleFunc("POST /api/issues", s.handleCreate)
	s.mux.HandleFunc("PATCH /api/issues/{id}", s.handleUpdateStatus)
	// 兜底：未匹配的路径返回 JSON 而不是 Go 默认的纯文本 404，
	// 这样前端/Unity 统一按 error.code 处理，不需要猜响应格式。
	s.mux.HandleFunc("/", s.handleNotFound)
	return s
}

// ServeHTTP 挂上 CORS、panic 恢复与请求日志。
//
// panic 恢复为什么必须有：`NewID` 在系统熵源坏掉时会 panic。
// 没有 recover 的话，一次请求的异常会让**整个服务退出**，
// Unity 那边看到的是"连接被断"而不是"服务器错误"，排查方向会被带偏。
func (s *Server) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Access-Control-Allow-Origin", "*")
	w.Header().Set("Access-Control-Allow-Methods", "GET, POST, PATCH, OPTIONS")
	w.Header().Set("Access-Control-Allow-Headers", "Content-Type")
	if r.Method == http.MethodOptions {
		w.WriteHeader(http.StatusNoContent)
		return
	}
	defer func() {
		if rec := recover(); rec != nil {
			log.Printf("处理 %s %s 时 panic: %v", r.Method, r.URL.Path, rec)
			writeError(w, http.StatusInternalServerError, "internal_error", "服务器内部错误")
		}
	}()
	start := time.Now()
	s.mux.ServeHTTP(w, r)
	log.Printf("%s %s (%s)", r.Method, r.URL.Path, time.Since(start).Round(time.Millisecond))
}

func (s *Server) handleHealth(w http.ResponseWriter, _ *http.Request) {
	writeJSON(w, http.StatusOK, map[string]any{"ok": true, "service": "holocode-inspection", "time": s.now().UTC().Format(time.RFC3339)})
}

func (s *Server) handleList(w http.ResponseWriter, _ *http.Request) {
	// 包一层 {"items": [...]} 而不是直接返回数组：以后要加分页/统计时，
	// 加字段不会破坏客户端解析（数组变对象是破坏性变更）。
	writeJSON(w, http.StatusOK, map[string]any{"items": s.store.List()})
}

// createRequest 是 POST /api/issues 的入参。
//
// 刻意**不含 status/id/createdAt**：这三个字段由服务端决定。
// 如果照抄 Issue 直接用，客户端就能传 status=resolved 绕过"默认 open"的要求。
type createRequest struct {
	Title       string   `json:"title"`
	Description string   `json:"description"`
	Priority    Priority `json:"priority"`
	Position    Position `json:"position"`
}

func (s *Server) handleCreate(w http.ResponseWriter, r *http.Request) {
	var req createRequest
	dec := json.NewDecoder(http.MaxBytesReader(w, r.Body, 64<<10))
	dec.DisallowUnknownFields() // 字段拼错要报错，而不是静默丢掉（Unity 端 JSON 手写容易错）
	if err := dec.Decode(&req); err != nil {
		writeError(w, http.StatusBadRequest, "bad_json", "请求体不是合法 JSON: "+err.Error())
		return
	}

	issue, err := s.store.Create(Issue{
		Title:       req.Title,
		Description: req.Description,
		Priority:    req.Priority,
		Position:    req.Position,
	}, s.now())
	if err != nil {
		writeFieldError(w, err)
		return
	}
	writeJSON(w, http.StatusCreated, map[string]any{"item": issue})
}

// updateStatusRequest 是 PATCH 的入参：只允许改 status。
type updateStatusRequest struct {
	Status Status `json:"status"`
}

func (s *Server) handleUpdateStatus(w http.ResponseWriter, r *http.Request) {
	id := r.PathValue("id")
	if strings.TrimSpace(id) == "" {
		writeError(w, http.StatusBadRequest, "id_required", "缺少问题 ID")
		return
	}

	var req updateStatusRequest
	dec := json.NewDecoder(http.MaxBytesReader(w, r.Body, 8<<10))
	dec.DisallowUnknownFields()
	if err := dec.Decode(&req); err != nil {
		writeError(w, http.StatusBadRequest, "bad_json", "请求体不是合法 JSON: "+err.Error())
		return
	}

	issue, err := s.store.UpdateStatus(id, req.Status, s.now())
	if err != nil {
		writeFieldError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"item": issue})
}

func (s *Server) handleNotFound(w http.ResponseWriter, r *http.Request) {
	writeError(w, http.StatusNotFound, "not_found", "没有这个接口: "+r.Method+" "+r.URL.Path)
}

// writeFieldError 把 domain 错误翻译成 HTTP 状态码。
//
// 这个映射是**唯一**一处：如果散落在各 handler 里，"参数错返回 400"这条要求
// 迟早会在某个新接口上变成 500。
func writeFieldError(w http.ResponseWriter, err error) {
	var fe *FieldError
	switch {
	case errors.As(err, &fe):
		writeError(w, http.StatusBadRequest, fe.Code, fe.Message)
	case errors.Is(err, errNotFound):
		writeError(w, http.StatusNotFound, "issue_not_found", "没有这个 ID 的问题")
	default:
		// 落盘失败等内部错误：500 + 明确说明"没有保存成功"，
		// 而不是吞掉后返回 200（那会让 Unity 以为上报成功，问题却没了）。
		writeError(w, http.StatusInternalServerError, "internal_error", "服务器内部错误: "+err.Error())
	}
}

// writeJSON 统一响应格式并设置 Content-Type。
func writeJSON(w http.ResponseWriter, status int, body any) {
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.WriteHeader(status)
	if err := json.NewEncoder(w).Encode(body); err != nil {
		log.Printf("写响应失败: %v", err)
	}
}

// writeError 输出 {"error":{"code","message"}}。
//
// code 是给程序看的（前端/Unity 靠它分支），message 是给人看的。
// 两者都给，是因为"只有 message"会让客户端去匹配字符串（脆），
// "只有 code"会让人看不懂发生了什么。
func writeError(w http.ResponseWriter, status int, code, message string) {
	writeJSON(w, status, map[string]any{
		"error": map[string]string{"code": code, "message": message},
	})
}
