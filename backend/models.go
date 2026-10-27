// Package main 实现巡检问题的后端 API。
//
// 设计取舍（为什么这样做，而不是"更完整"的做法）：
//  1. **零第三方依赖**：只用标准库。作业要求"能跑起来"，而任何外部依赖都会引入
//     `go mod download` 失败的可能；评卷人在断网环境里 clone 下来也必须能 build。
//  2. **JSON 文件持久化**（题目允许）：SQLite 的纯 Go 驱动要下载依赖、
//     CGO 版又要装 C 编译器。这个原型的数据量是"几条到几百条"，文件足够，
//     而且"重启后数据还在"这条要求用文件最简单、最容易验证。
//  3. **字段与题目给定的结构逐字一致**（id/title/description/priority/status/
//     position{x,y,z}/createdAt/updatedAt）。三端共用一套字段名是题目明确要求，
//     所以在 Go 里也用 json tag 固定下来，不给"前端自己改名"留空间。
package main

import (
	"errors"
	"fmt"
	"strings"
	"time"
)

// Priority 与 Status 用自定义类型而不是裸 string：
// 枚举校验要在**一处**完成，否则每个 handler 都会各写一遍 if，慢慢就不一致了。
type Priority string

type Status string

const (
	PriorityLow    Priority = "low"
	PriorityMedium Priority = "medium"
	PriorityHigh   Priority = "high"

	StatusOpen       Status = "open"
	StatusInProgress Status = "in_progress"
	StatusResolved   Status = "resolved"
)

// Position 是 AR 真机放置标记时的世界坐标（单位米，Unity 的 AR 空间单位）。
// 题目明确"不要求重启后恢复真实物理位置"，所以这里只做记录，不做恢复。
type Position struct {
	X float64 `json:"x"`
	Y float64 `json:"y"`
	Z float64 `json:"z"`
}

// Issue 是一条巡检问题。字段名与题目第 4 节的示例逐字相同。
type Issue struct {
	ID          string   `json:"id"`
	Title       string   `json:"title"`
	Description string   `json:"description"`
	Priority    Priority `json:"priority"`
	Status      Status   `json:"status"`
	Position    Position `json:"position"`
	CreatedAt   string   `json:"createdAt"`
	UpdatedAt   string   `json:"updatedAt"`
}

// ValidPriority 报告 p 是否是允许的优先级。
func ValidPriority(p Priority) bool {
	switch p {
	case PriorityLow, PriorityMedium, PriorityHigh:
		return true
	}
	return false
}

// ValidStatus 报告 s 是否是允许的状态。
func ValidStatus(s Status) bool {
	switch s {
	case StatusOpen, StatusInProgress, StatusResolved:
		return true
	}
	return false
}

// FieldError 表示某个字段不合法的参数错误。
//
// 为什么要分类而不是笼统返回 "bad request"：
// 题目 3.3.6 要求"标题为空或枚举值错误时，返回明确的参数错误"，
// 前端/Unity 拿到 code 才能显示"是标题没填"还是"优先级选错了"。
type FieldError struct {
	Field   string
	Code    string
	Message string
}

func (e *FieldError) Error() string {
	return fmt.Sprintf("%s: %s (%s)", e.Field, e.Message, e.Code)
}

// Validate 校验"新建问题"的输入，并补齐服务端该给的默认值。
//
// 保证：title 非空（去首尾空白后）、priority 合法、status 永远由服务端决定（open）。
// 不保证：description 的长度上限之外的语义（这属于业务规则，原型不引入）。
// 重要：**status 不接受客户端传入**——新建时一律 open，否则"默认状态为 open"这条要求
// 就变成了"客户端说是 open 就是 open"，评审无法验证。
func (in *Issue) Validate() error {
	in.Title = strings.TrimSpace(in.Title)
	in.Description = strings.TrimSpace(in.Description)

	if in.Title == "" {
		return &FieldError{Field: "title", Code: "title_required", Message: "标题不能为空"}
	}
	if len([]rune(in.Title)) > 200 {
		return &FieldError{Field: "title", Code: "title_too_long", Message: "标题不能超过 200 个字符"}
	}
	// Arduino 风格的空串优先级：给个默认值 medium，避免 Unity 忘记传就被打回。
	// 这是刻意的"宽容"，但**非法值不宽容**（见下），否则枚举校验形同虚设。
	if in.Priority == "" {
		in.Priority = PriorityMedium
	}
	if !ValidPriority(in.Priority) {
		return &FieldError{
			Field:   "priority",
			Code:    "priority_invalid",
			Message: fmt.Sprintf("priority 必须是 low/medium/high，收到 %q", in.Priority),
		}
	}
	if err := in.Position.Validate(); err != nil {
		return err
	}
	in.Status = StatusOpen
	return nil
}

// Validate 检查坐标是有限数。
//
// 为什么必须查：JSON 里的 `NaN`/`Infinity` 在部分客户端会把坐标变成 NaN，
// 而 NaN 一旦落盘，前端显示就是 `NaN`，看起来像"后端坏了"。
func (p Position) Validate() error {
	for name, v := range map[string]float64{"x": p.X, "y": p.Y, "z": p.Z} {
		// NaN != NaN 是唯一可靠的 NaN 判断方式（标准库 math.IsNaN 也可以，这里显式写出来）。
		if v != v || v > 1e9 || v < -1e9 {
			return &FieldError{
				Field:   "position." + name,
				Code:    "position_invalid",
				Message: "坐标必须是有限数值且绝对值不超过 1e9",
			}
		}
	}
	return nil
}

// NewID 生成问题 ID。
//
// 形状是"毫秒时间戳 + 8 字节随机十六进制"：
//   - 时间戳让 ID 大体按创建顺序递增，排查日志时肉眼可读；
//   - 随机后缀让同一毫秒内建多条**几乎**不会撞：碰撞概率约 2^-64，
//     在"几百条"这个量级上可以忽略，但它仍是**概率唯一**，不是数学上的确定唯一。
//     （要确定唯一就得引入序列号或 UUIDv7 生成器，对原型没有必要。）
//
// 它只是个标识、不是令牌，不需要密码学强度。
func NewID(now time.Time) string {
	return fmt.Sprintf("%d-%s", now.UnixMilli(), randomHex(8))
}

// errNotFound 由 store 返回；handler 据此给出 404 而不是 500。
var errNotFound = errors.New("issue not found")
