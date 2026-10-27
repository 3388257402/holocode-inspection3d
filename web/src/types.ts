/** 与后端逐字一致的字段（题目第 4 节）。改这里必须同时改 Go 的 models.go。 */
export type Priority = "low" | "medium" | "high";
export type Status = "open" | "in_progress" | "resolved";

export interface Position {
  x: number;
  y: number;
  z: number;
}

export interface Issue {
  id: string;
  title: string;
  description: string;
  priority: Priority;
  status: Status;
  position: Position;
  createdAt: string;
  updatedAt: string;
}
