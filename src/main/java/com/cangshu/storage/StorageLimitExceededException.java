package com.cangshu.storage;

/** 字节层单文件上限异常（storage 不依赖 catalog，由 ingest 翻译为业务错误码）。 */
public class StorageLimitExceededException extends RuntimeException {

    private final long maxBytes;
    private final long receivedBytes;

    public StorageLimitExceededException(long maxBytes, long receivedBytes) {
        super("单文件上限 " + maxBytes + " 字节（已接收 " + receivedBytes + " 字节）");
        this.maxBytes = maxBytes;
        this.receivedBytes = receivedBytes;
    }

    public long maxBytes() {
        return maxBytes;
    }

    public long receivedBytes() {
        return receivedBytes;
    }
}
