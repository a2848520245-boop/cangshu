package com.cangshu.storage;

import java.util.concurrent.TimeUnit;
import java.util.concurrent.locks.ReentrantLock;
import org.springframework.stereotype.Component;

/**
 * 分段锁（DEC-T2 ＋ I7）：锁键＝算法＋摘要（不含大小）；上传／复用／还原／删除／GC／对账共锁。
 *
 * <p>容量预算（I7，初始工程参数）：固定数组 {@value #SEGMENT_COUNT} 段，不采用随资源量增长的
 * 锁表，也不采用「解锁即移除」；不同摘要落入同段可以串行，但不得产生错误的内容冲突。
 * 取锁顺序（04 §6）：先非阻塞尝试 → 等 50ms 再试 → 等 100ms 再试 → 最后一次最多阻塞 30 秒；
 * 仍失败则 {@link LockTimeoutException}（由 catalog 翻译为 503 SERVICE_BUSY，明确可重试）。
 */
@Component
public class SegmentLockManager {

    public static final int SEGMENT_COUNT = 4096;
    public static final long WAIT_TIMEOUT_SECONDS = 30L;

    static final long FIRST_BACKOFF_MILLIS = 50L;
    static final long SECOND_BACKOFF_MILLIS = 100L;

    private final ReentrantLock[] segments;

    public SegmentLockManager() {
        this.segments = new ReentrantLock[SEGMENT_COUNT];
        for (int index = 0; index < SEGMENT_COUNT; index++) {
            this.segments[index] = new ReentrantLock();
        }
    }

    /** 锁键：规范算法 ＋ 摘要，绝不含 size（DEC-T2）。 */
    public static String lockKey(String canonicalAlgorithm, String digest) {
        return canonicalAlgorithm.toUpperCase() + ":" + digest.toLowerCase();
    }

    /** 固定数组分段：同一键稳定落同一段；哈希碰撞只串行、不出错。 */
    static int segmentIndex(String lockKey) {
        return Math.floorMod(lockKey.hashCode(), SEGMENT_COUNT);
    }

    public Handle acquire(String canonicalAlgorithm, String digest) {
        String key = lockKey(canonicalAlgorithm, digest);
        ReentrantLock lock = segments[segmentIndex(key)];
        boolean acquired;
        try {
            acquired = lock.tryLock();
            if (!acquired) {
                Thread.sleep(FIRST_BACKOFF_MILLIS);
                acquired = lock.tryLock();
            }
            if (!acquired) {
                Thread.sleep(SECOND_BACKOFF_MILLIS);
                acquired = lock.tryLock();
            }
            if (!acquired) {
                acquired = lock.tryLock(WAIT_TIMEOUT_SECONDS, TimeUnit.SECONDS);
            }
        } catch (InterruptedException e) {
            Thread.currentThread().interrupt();
            throw new LockTimeoutException(key, "取分段锁被中断");
        }
        if (!acquired) {
            throw new LockTimeoutException(key, "等待分段锁超过 " + WAIT_TIMEOUT_SECONDS + " 秒");
        }
        return new Handle(lock, key);
    }

    /** 持锁句柄：持锁至文件操作与数据库提交结束（04 §4 前置顺序⑤）。 */
    public static final class Handle implements AutoCloseable {

        private final ReentrantLock lock;
        private final String key;

        Handle(ReentrantLock lock, String key) {
            this.lock = lock;
            this.key = key;
        }

        public String key() {
            return key;
        }

        @Override
        public void close() {
            lock.unlock();
        }
    }
}
