package com.cangshu.arch;

import static org.junit.jupiter.api.Assertions.assertTrue;
import static org.junit.jupiter.api.Assertions.fail;

import java.io.IOException;
import java.io.UncheckedIOException;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.regex.Matcher;
import java.util.regex.Pattern;
import java.util.stream.Stream;
import org.junit.jupiter.api.DisplayName;
import org.junit.jupiter.api.Test;

/**
 * 包级依赖结构的自动断言（P0-3④ 结构项）：把 04-架构与计划 §1 的禁边写成可执行证据。
 *
 * <p>为什么扫源码文本而不是 class 文件：仓内没有 ArchUnit／maven-dependency-plugin，
 * 本项**不引入新依赖**，只用 JDK ＋ JUnit 读 {@code src/main/java} 下的 {@code import}
 * 行。局限同样明确：只看显式 import（含 static import），同包内引用、完全限定名内联
 * 与反射不在覆盖范围内——它挡的是「顺手少写一个分层」的常态，不是恶意绕过。
 *
 * <p>单写者门协议文件名常量由 config 装配层传入 storage；当前 storage 无 config 导入。
 */
class DependencyStructureTests {

    /** {@code import [static] a.b.C;} 的导入目标。Javadoc 行以 {@code *} 起头，不会被匹配。 */
    private static final Pattern IMPORT = Pattern.compile("^\\s*import\\s+(?:static\\s+)?([\\w.]+)\\s*;");

    /** 源码树相对路径：surefire 的工作目录是模块根，故按模块根定位。 */
    private static final Path SOURCES = Path.of("src", "main", "java", "com", "cangshu");

    private static final List<String> BUSINESS_PACKAGES = List.of(
            "com.cangshu.api", "com.cangshu.catalog", "com.cangshu.ingest",
            "com.cangshu.search", "com.cangshu.job", "com.cangshu.migration");

    @Test
    @DisplayName("结构扫描自检：main 源码树可定位，各模块包都扫到源码（防止空跑通过）")
    void scanTargetsExist() {
        Path root = sourcesRoot();
        for (String pkg : List.of("api", "catalog", "ingest", "search", "job", "storage", "common", "config", "migration")) {
            assertTrue(!javaFiles(root.resolve(pkg)).isEmpty(),
                    "扫不到源码的包：" + pkg + "（定位根：" + root + "）");
        }
    }

    @Test
    @DisplayName("api 不依赖 storage 的算法／路径实现（P0-3④ B：显示值归 api）")
    void apiDoesNotDependOnStorage() {
        assertNoForbiddenImports("api", List.of("com.cangshu.storage"));
    }

    @Test
    @DisplayName("catalog 不依赖 ingest 的上传暂存类型（P0-3④ A：载荷归 common）")
    void catalogDoesNotDependOnIngest() {
        assertNoForbiddenImports("catalog", List.of("com.cangshu.ingest"));
    }

    @Test
    @DisplayName("storage 不依赖任何业务模块（04 §1 方向图：storage → 无）")
    void storageDoesNotDependOnBusinessModules() {
        assertNoForbiddenImports("storage", BUSINESS_PACKAGES);
    }

    @Test
    @DisplayName("storage 不读业务配置绑定面（P0-3④ D：数据根由装配层解析后注入）")
    void storageDoesNotReadConfigurationProperties() {
        assertNoForbiddenImports("storage", List.of("com.cangshu.config.CangshuProperties"));
    }

    @Test
    @DisplayName("common 保持中性：只放无业务状态的通用值，不依赖任何业务模块（P0-3④ A）")
    void commonStaysNeutral() {
        assertNoForbiddenImports("common", BUSINESS_PACKAGES);
    }

    /** 逐文件比对 import 目标：等值或落在禁止前缀的子包内都算违规，失败消息给出文件与具体 import。 */
    private static void assertNoForbiddenImports(String pkg, List<String> forbidden) {
        Path root = sourcesRoot();
        List<Path> files = javaFiles(root.resolve(pkg));
        assertTrue(!files.isEmpty(), "没有扫到 " + pkg + " 包的源码，断言失效（定位根：" + root + "）");

        Map<String, List<String>> violations = new LinkedHashMap<>();
        for (Path file : files) {
            String relative = root.relativize(file).toString().replace('\\', '/');
            for (String imported : importsOf(file)) {
                for (String prefix : forbidden) {
                    if (imported.equals(prefix) || imported.startsWith(prefix + ".")) {
                        violations.computeIfAbsent(relative, key -> new ArrayList<>()).add(imported);
                    }
                }
            }
        }
        if (!violations.isEmpty()) {
            fail(pkg + " 包出现被禁止的依赖边（04-架构与计划 §1）：" + violations);
        }
    }

    /** 一个源文件里所有 import 的目标全名（含 static import）。 */
    private static List<String> importsOf(Path file) {
        List<String> targets = new ArrayList<>();
        try {
            for (String line : Files.readAllLines(file, StandardCharsets.UTF_8)) {
                Matcher matcher = IMPORT.matcher(line);
                if (matcher.find()) {
                    targets.add(matcher.group(1));
                }
            }
        } catch (IOException e) {
            throw new UncheckedIOException(e);
        }
        return targets;
    }

    private static List<Path> javaFiles(Path dir) {
        if (!Files.isDirectory(dir)) {
            return List.of();
        }
        try (Stream<Path> walk = Files.walk(dir)) {
            return walk.filter(path -> path.toString().endsWith(".java")).sorted().toList();
        } catch (IOException e) {
            throw new UncheckedIOException(e);
        }
    }

    /** 模块根下的 {@code src/main/java/com/cangshu}；工作目录异常时向上一级再找，找不到即失败。 */
    private static Path sourcesRoot() {
        Path dir = Path.of("").toAbsolutePath();
        for (int depth = 0; depth < 4 && dir != null; depth++, dir = dir.getParent()) {
            Path candidate = dir.resolve(SOURCES);
            if (Files.isDirectory(candidate)) {
                return candidate;
            }
        }
        return fail("定位不到 " + SOURCES + "，当前工作目录：" + Path.of("").toAbsolutePath());
    }
}
