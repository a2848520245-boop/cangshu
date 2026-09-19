package com.cangshu.api;

import com.cangshu.config.CangshuProperties;
import jakarta.servlet.MultipartConfigElement;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import org.springframework.util.unit.DataSize;

/**
 * HTTP 层 multipart 限制与业务上限同源（07-运行手册 §1）：
 * {@code max-file-size}＝{@code cangshu.upload.max-size}；请求上限还需容纳协议开销，
 * 不能把整个请求上限直接等同于文件字节上限（这里加 1MB 余量）。
 * 提供本 Bean 后 Boot 的 MultipartProperties 自动配置不再生效，上限只此一处来源。
 */
@Configuration
public class MultipartLimitsConfig {

    /** 请求协议开销余量（multipart 边界与字段开销）。 */
    static final DataSize REQUEST_OVERHEAD = DataSize.ofMegabytes(1);

    /** 超过阈值的分片先由 Tomcat 落磁盘，业务层再流式落数据根临时区。 */
    static final DataSize FILE_SIZE_THRESHOLD = DataSize.ofMegabytes(1);

    @Bean
    public MultipartConfigElement multipartConfigElement(CangshuProperties properties) {
        long maxFileBytes = properties.getUpload().getMaxSize().toBytes();
        long maxRequestBytes = maxFileBytes + REQUEST_OVERHEAD.toBytes();
        return new MultipartConfigElement("", maxFileBytes, maxRequestBytes,
                (int) FILE_SIZE_THRESHOLD.toBytes());
    }
}
