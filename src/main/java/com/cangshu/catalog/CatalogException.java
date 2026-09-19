package com.cangshu.catalog;

/**
 * catalog 业务异常：错误码与 HTTP 状态对齐《05-M1-接口契约》§2（扁平错误体；
 * {@code reason} 可选，冲突响应中必填——I1）。
 */
public class CatalogException extends RuntimeException {

    public enum Code {
        INVALID_ARGUMENT(400),
        RESOURCE_NOT_FOUND(404),
        CONTENT_CONFLICT(409),
        PAYLOAD_TOO_LARGE(413),
        HASH_MISMATCH(422),
        SERVICE_BUSY(503),
        INTERNAL_ERROR(500);

        private final int httpStatus;

        Code(int httpStatus) {
            this.httpStatus = httpStatus;
        }

        public int httpStatus() {
            return httpStatus;
        }
    }

    private final Code code;
    private final String reason;

    public CatalogException(Code code, String message, String reason) {
        super(message);
        this.code = code;
        this.reason = reason;
    }

    public Code code() {
        return code;
    }

    /** 冲突原因词表取值（SIZE_MISMATCH／BYTE_MISMATCH／TARGET_PATH_EXISTS）；非冲突为 null。 */
    public String reason() {
        return reason;
    }

    public static CatalogException invalidArgument(String message) {
        return new CatalogException(Code.INVALID_ARGUMENT, message, null);
    }

    public static CatalogException conflict(String reason, String message) {
        return new CatalogException(Code.CONTENT_CONFLICT, message, reason);
    }

    public static CatalogException payloadTooLarge(String message) {
        return new CatalogException(Code.PAYLOAD_TOO_LARGE, message, null);
    }

    public static CatalogException hashMismatch(String message) {
        return new CatalogException(Code.HASH_MISMATCH, message, null);
    }

    public static CatalogException serviceBusy(String message) {
        return new CatalogException(Code.SERVICE_BUSY, message, null);
    }

    public static CatalogException internalError(String message) {
        return new CatalogException(Code.INTERNAL_ERROR, message, null);
    }
}
