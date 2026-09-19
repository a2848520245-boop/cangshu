package com.cangshu.api;

import com.cangshu.api.dto.ErrorResponse;
import com.cangshu.catalog.CatalogException;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.http.HttpStatus;
import org.springframework.http.ResponseEntity;
import org.springframework.http.converter.HttpMessageNotReadableException;
import org.springframework.web.HttpRequestMethodNotSupportedException;
import org.springframework.web.bind.MissingServletRequestParameterException;
import org.springframework.web.bind.annotation.ExceptionHandler;
import org.springframework.web.bind.annotation.RestControllerAdvice;
import org.springframework.web.multipart.MaxUploadSizeExceededException;
import org.springframework.web.multipart.MultipartException;
import org.springframework.web.multipart.support.MissingServletRequestPartException;
import org.springframework.web.servlet.resource.NoResourceFoundException;

/**
 * 契约错误码映射（api 模块：收发 HTTP、参数校验、错误码映射；M1 不鉴权）。
 * 错误体见《05-M1-接口契约》§2；未预期异常一律 {@code INTERNAL_ERROR}（500）。
 */
@RestControllerAdvice
public class ApiExceptionHandler {

    private static final Logger log = LoggerFactory.getLogger(ApiExceptionHandler.class);

    @ExceptionHandler(CatalogException.class)
    public ResponseEntity<ErrorResponse> handleCatalog(CatalogException exception) {
        if (exception.code() == CatalogException.Code.INTERNAL_ERROR) {
            log.error("CANGSHU|internal-error|{}", exception.getMessage());
        }
        return ResponseEntity.status(exception.code().httpStatus()).body(ErrorResponse.of(exception));
    }

    @ExceptionHandler({MissingServletRequestPartException.class, MissingServletRequestParameterException.class})
    public ResponseEntity<ErrorResponse> handleMissingPart(Exception exception) {
        return respond(HttpStatus.BAD_REQUEST, CatalogException.invalidArgument(
                "缺少必填的 multipart 字段 file"));
    }

    @ExceptionHandler(MaxUploadSizeExceededException.class)
    public ResponseEntity<ErrorResponse> handleMaxUpload(MaxUploadSizeExceededException exception) {
        return respond(HttpStatus.PAYLOAD_TOO_LARGE, CatalogException.payloadTooLarge(
                "单文件超过上限，请减小文件或联系管理员调整配置"));
    }

    @ExceptionHandler({MultipartException.class, HttpMessageNotReadableException.class})
    public ResponseEntity<ErrorResponse> handleMultipart(Exception exception) {
        return respond(HttpStatus.BAD_REQUEST,
                CatalogException.invalidArgument("请求格式错误：" + exception.getClass().getSimpleName()));
    }

    @ExceptionHandler(NoResourceFoundException.class)
    public ResponseEntity<ErrorResponse> handleNoResource(NoResourceFoundException exception) {
        return respond(HttpStatus.NOT_FOUND, new CatalogException(
                CatalogException.Code.RESOURCE_NOT_FOUND, "资源不存在", null));
    }

    @ExceptionHandler(HttpRequestMethodNotSupportedException.class)
    public ResponseEntity<ErrorResponse> handleMethodNotSupported(HttpRequestMethodNotSupportedException exception) {
        return respond(HttpStatus.BAD_REQUEST,
                CatalogException.invalidArgument("不支持的请求方法"));
    }

    @ExceptionHandler(Exception.class)
    public ResponseEntity<ErrorResponse> handleUnexpected(Exception exception) {
        log.error("CANGSHU|internal-error|unexpected {}", exception.getClass().getSimpleName(), exception);
        return respond(HttpStatus.INTERNAL_SERVER_ERROR,
                CatalogException.internalError("服务内部错误，请稍后重试"));
    }

    private ResponseEntity<ErrorResponse> respond(HttpStatus status, CatalogException exception) {
        return ResponseEntity.status(status).body(ErrorResponse.of(exception));
    }
}
