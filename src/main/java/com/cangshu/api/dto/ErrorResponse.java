package com.cangshu.api.dto;

import com.fasterxml.jackson.annotation.JsonInclude;

/**
 * 统一错误体（05-接口契约 §2）：扁平对象；{@code reason} 可选，冲突响应中必填（I1）。
 */
@JsonInclude(JsonInclude.Include.NON_NULL)
public record ErrorResponse(String code, String message, String reason) {

    public static ErrorResponse of(com.cangshu.catalog.CatalogException exception) {
        return new ErrorResponse(exception.code().name(), exception.getMessage(), exception.reason());
    }
}
