package com.cangshu.api.dto;

/**
 * 清空回收站响应（05-接口契约 §3.8）：{@code { "deletedCount": 3 }}——唯一字段。
 */
public record EmptyTrashResponse(int deletedCount) {
}
