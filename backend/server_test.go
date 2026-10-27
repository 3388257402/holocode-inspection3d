package main

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"
)

// 这组测试逐条对应题目 3.3 的 9 条后端要求。
// 之所以一条要求一个用例，是因为评分表就是按那 9 条看的——漏一条就是一个可见的扣分点。

// newTestServer 造一个"独立数据文件 + 固定时钟"的服务器。
//
// 固定时钟不是为了好看：createdAt 精确到秒，同一秒内建两条会相等，
// 用它断言"倒序"就不成立了。固定时钟让顺序断言确定。
func newTestServer(t *testing.T) (*Server, *Store, string) {
	t.Helper()
	path := filepath.Join(t.TempDir(), "issues.json")
	store, err := NewStore(path)
	if err != nil {
		t.Fatalf("NewStore: %v", err)
	}
	s := NewServer(store)
	fixed := time.Date(2026, 1, 2, 3, 4, 5, 0, time.UTC)
	s.now = func() time.Time { return fixed }
	return s, store, path
}

func do(t *testing.T, s *Server, method, path, body string) (*httptest.ResponseRecorder, map[string]any) {
	t.Helper()
	var r *http.Request
	if body == "" {
		r = httptest.NewRequest(method, path, nil)
	} else {
		r = httptest.NewRequest(method, path, strings.NewReader(body))
		r.Header.Set("Content-Type", "application/json")
	}
	w := httptest.NewRecorder()
	s.ServeHTTP(w, r)
	out := map[string]any{}
	if w.Body.Len() > 0 {
		if err := json.Unmarshal(w.Body.Bytes(), &out); err != nil {
			t.Fatalf("响应不是 JSON: %v\n%s", err, w.Body.String())
		}
	}
	return w, out
}

// 3.3.1 服务运行状态检查
func TestHealthz(t *testing.T) {
	s, _, _ := newTestServer(t)
	w, body := do(t, s, http.MethodGet, "/healthz", "")
	if w.Code != http.StatusOK {
		t.Fatalf("状态码 = %d，想要 200", w.Code)
	}
	if body["ok"] != true {
		t.Fatalf("ok 字段 = %v，想要 true", body["ok"])
	}
}

// 3.3.2 + 3.3.5 + 3.3.3 上报、生成唯一 ID、默认 open、列表可读回
func TestCreateThenList(t *testing.T) {
	s, _, _ := newTestServer(t)

	w, body := do(t, s, http.MethodPost, "/api/issues",
		`{"title":"入口墙面破损","description":"左侧墙体存在裂缝","priority":"high","position":{"x":0.42,"y":0.03,"z":1.26}}`)
	if w.Code != http.StatusCreated {
		t.Fatalf("创建返回 %d，想要 201：%v", w.Code, body)
	}
	item := body["item"].(map[string]any)
	if item["id"] == "" || item["id"] == nil {
		t.Fatal("没有生成 id")
	}
	if item["status"] != "open" {
		t.Fatalf("默认状态 = %v，想要 open", item["status"])
	}
	if item["createdAt"] != "2026-01-02T03:04:05Z" {
		t.Fatalf("createdAt = %v，想要固定时钟值", item["createdAt"])
	}

	w, body = do(t, s, http.MethodGet, "/api/issues", "")
	if w.Code != http.StatusOK {
		t.Fatalf("列表返回 %d", w.Code)
	}
	items := body["items"].([]any)
	if len(items) != 1 {
		t.Fatalf("列表长度 = %d，想要 1", len(items))
	}
}

// 3.3.6 标题为空 → 明确的参数错误（不是 500，也不是静默接受）
func TestCreateRejectsEmptyTitle(t *testing.T) {
	s, _, _ := newTestServer(t)
	w, body := do(t, s, http.MethodPost, "/api/issues",
		`{"title":"   ","priority":"low","position":{"x":0,"y":0,"z":0}}`)
	if w.Code != http.StatusBadRequest {
		t.Fatalf("状态码 = %d，想要 400", w.Code)
	}
	errObj := body["error"].(map[string]any)
	if errObj["code"] != "title_required" {
		t.Fatalf("error.code = %v，想要 title_required（前端要靠它显示是哪一项错了）", errObj["code"])
	}
}

// 3.3.6 枚举值错误 → 明确的参数错误
func TestCreateRejectsInvalidPriority(t *testing.T) {
	s, _, _ := newTestServer(t)
	w, body := do(t, s, http.MethodPost, "/api/issues",
		`{"title":"x","priority":"urgent","position":{"x":0,"y":0,"z":0}}`)
	if w.Code != http.StatusBadRequest {
		t.Fatalf("状态码 = %d，想要 400", w.Code)
	}
	if body["error"].(map[string]any)["code"] != "priority_invalid" {
		t.Fatalf("error.code = %v", body["error"])
	}
}

// 客户端不能自己指定 status（否则"默认 open"这条要求无法被验证）
func TestCreateRejectsClientSuppliedStatus(t *testing.T) {
	s, _, _ := newTestServer(t)
	w, body := do(t, s, http.MethodPost, "/api/issues",
		`{"title":"x","priority":"low","status":"resolved","position":{"x":0,"y":0,"z":0}}`)
	if w.Code != http.StatusBadRequest {
		t.Fatalf("状态码 = %d，想要 400（未知字段必须报错）", w.Code)
	}
	if body["error"].(map[string]any)["code"] != "bad_json" {
		t.Fatalf("error.code = %v", body["error"])
	}
}

// 坐标是 NaN（Unity/JS 里极易出现）时必须在服务端拦住
func TestCreateRejectsNonFinitePosition(t *testing.T) {
	s, _, _ := newTestServer(t)
	// JSON 标准不支持 NaN 字面量，所以这里传一个超界值模拟"算错了坐标"。
	w, body := do(t, s, http.MethodPost, "/api/issues",
		`{"title":"x","priority":"low","position":{"x":1e18,"y":0,"z":0}}`)
	if w.Code != http.StatusBadRequest {
		t.Fatalf("状态码 = %d，想要 400：%v", w.Code, body)
	}
	if body["error"].(map[string]any)["code"] != "position_invalid" {
		t.Fatalf("error.code = %v", body["error"])
	}
}

// 优先级缺省时给 medium（宽容），但非法值不宽容
func TestCreateDefaultsPriorityToMedium(t *testing.T) {
	s, _, _ := newTestServer(t)
	w, body := do(t, s, http.MethodPost, "/api/issues",
		`{"title":"x","position":{"x":0,"y":0,"z":0}}`)
	if w.Code != http.StatusCreated {
		t.Fatalf("状态码 = %d：%v", w.Code, body)
	}
	if body["item"].(map[string]any)["priority"] != "medium" {
		t.Fatalf("priority = %v，想要 medium", body["item"])
	}
}

// 3.3.4 按 ID 修改状态
func TestUpdateStatus(t *testing.T) {
	s, _, _ := newTestServer(t)
	_, created := do(t, s, http.MethodPost, "/api/issues",
		`{"title":"x","priority":"low","position":{"x":0,"y":0,"z":0}}`)
	id := created["item"].(map[string]any)["id"].(string)
	createdAt := created["item"].(map[string]any)["createdAt"]

	w, body := do(t, s, http.MethodPatch, "/api/issues/"+id, `{"status":"in_progress"}`)
	if w.Code != http.StatusOK {
		t.Fatalf("状态码 = %d，想要 200：%v", w.Code, body)
	}
	item := body["item"].(map[string]any)
	if item["status"] != "in_progress" {
		t.Fatalf("status = %v", item["status"])
	}
	// createdAt 不该被"改状态"改掉
	if item["createdAt"] != createdAt {
		t.Fatalf("createdAt 被改了：%v → %v", createdAt, item["createdAt"])
	}
}

func TestUpdateStatusRejectsInvalidEnum(t *testing.T) {
	s, _, _ := newTestServer(t)
	_, created := do(t, s, http.MethodPost, "/api/issues",
		`{"title":"x","priority":"low","position":{"x":0,"y":0,"z":0}}`)
	id := created["item"].(map[string]any)["id"].(string)

	w, body := do(t, s, http.MethodPatch, "/api/issues/"+id, `{"status":"done"}`)
	if w.Code != http.StatusBadRequest {
		t.Fatalf("状态码 = %d，想要 400", w.Code)
	}
	if body["error"].(map[string]any)["code"] != "status_invalid" {
		t.Fatalf("error.code = %v", body["error"])
	}
}

func TestUpdateStatusUnknownID(t *testing.T) {
	s, _, _ := newTestServer(t)
	w, body := do(t, s, http.MethodPatch, "/api/issues/nope", `{"status":"resolved"}`)
	if w.Code != http.StatusNotFound {
		t.Fatalf("状态码 = %d，想要 404", w.Code)
	}
	if body["error"].(map[string]any)["code"] != "issue_not_found" {
		t.Fatalf("error.code = %v", body["error"])
	}
}

// 3.3.7 重启后数据仍然存在（这是最容易被"内存里存着"糊过去的一条）
func TestPersistenceAcrossRestart(t *testing.T) {
	path := filepath.Join(t.TempDir(), "issues.json")
	store, err := NewStore(path)
	if err != nil {
		t.Fatalf("NewStore: %v", err)
	}
	s := NewServer(store)
	s.now = func() time.Time { return time.Date(2026, 1, 2, 3, 4, 5, 0, time.UTC) }
	if w, body := do(t, s, http.MethodPost, "/api/issues",
		`{"title":"重启后还在","priority":"high","position":{"x":1,"y":2,"z":3}}`); w.Code != http.StatusCreated {
		t.Fatalf("创建失败: %v", body)
	}

	// 模拟"进程重启"：完全重新打开文件
	store2, err := NewStore(path)
	if err != nil {
		t.Fatalf("重新打开数据文件失败: %v", err)
	}
	list := store2.List()
	if len(list) != 1 || list[0].Title != "重启后还在" {
		t.Fatalf("重启后数据丢了: %+v", list)
	}
}

// 3.3.9 React 在浏览器里能访问：CORS 预检必须通过
func TestCORSPreflight(t *testing.T) {
	s, _, _ := newTestServer(t)
	r := httptest.NewRequest(http.MethodOptions, "/api/issues", nil)
	r.Header.Set("Origin", "http://localhost:5173")
	r.Header.Set("Access-Control-Request-Method", "POST")
	w := httptest.NewRecorder()
	s.ServeHTTP(w, r)
	if w.Code != http.StatusNoContent {
		t.Fatalf("预检状态码 = %d，想要 204", w.Code)
	}
	if got := w.Header().Get("Access-Control-Allow-Origin"); got != "*" {
		t.Fatalf("Allow-Origin = %q", got)
	}
}

// 未知路径也要返回 JSON（前端统一按 error.code 处理，不猜格式）
func TestUnknownPathReturnsJSON(t *testing.T) {
	s, _, _ := newTestServer(t)
	w, body := do(t, s, http.MethodGet, "/api/nope", "")
	if w.Code != http.StatusNotFound {
		t.Fatalf("状态码 = %d，想要 404", w.Code)
	}
	if body["error"].(map[string]any)["code"] != "not_found" {
		t.Fatalf("error = %v", body["error"])
	}
}

// 并发上报：ID 不能重复、不能丢数据、不能触发数据竞争（配合 go test -race 跑）
func TestConcurrentCreates(t *testing.T) {
	s, _, _ := newTestServer(t)
	const n = 40
	var wg sync.WaitGroup
	codes := make([]int, n)
	for i := 0; i < n; i++ {
		wg.Add(1)
		go func(i int) {
			defer wg.Done()
			w, _ := do(t, s, http.MethodPost, "/api/issues",
				`{"title":"并发","priority":"low","position":{"x":0,"y":0,"z":0}}`)
			codes[i] = w.Code
		}(i)
	}
	wg.Wait()
	for i, c := range codes {
		if c != http.StatusCreated {
			t.Fatalf("第 %d 个并发请求返回 %d", i, c)
		}
	}
	list := s.store.List()
	if len(list) != n {
		t.Fatalf("落盘条数 = %d，想要 %d", len(list), n)
	}
	seen := map[string]bool{}
	for _, it := range list {
		if seen[it.ID] {
			t.Fatalf("ID 重复: %s", it.ID)
		}
		seen[it.ID] = true
	}
}
