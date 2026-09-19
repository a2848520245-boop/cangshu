package com.cangshu.storage;

/** 分段锁等待超时／被中断（storage 层异常，由 catalog 翻译为 SERVICE_BUSY）。 */
public class LockTimeoutException extends RuntimeException {

    private final String lockKey;

    public LockTimeoutException(String lockKey, String message) {
        super(message);
        this.lockKey = lockKey;
    }

    public String lockKey() {
        return lockKey;
    }
}
