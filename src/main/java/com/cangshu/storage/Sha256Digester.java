package com.cangshu.storage;

import java.security.MessageDigest;
import java.security.NoSuchAlgorithmException;
import org.springframework.stereotype.Component;

/** 生产摘要器：SHA-256（REQ-M1-02：边接收边计算 SHA-256）。 */
@Component
public class Sha256Digester implements Digestor {

    @Override
    public String canonicalAlgorithm() {
        return Algorithms.CANONICAL_SHA256;
    }

    @Override
    public MessageDigest create() {
        try {
            return MessageDigest.getInstance("SHA-256");
        } catch (NoSuchAlgorithmException e) {
            throw new IllegalStateException("JVM 不提供 SHA-256", e);
        }
    }
}
