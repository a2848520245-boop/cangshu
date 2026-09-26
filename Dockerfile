# 仓鼠 M1 交付态运行镜像（07-运行手册 §3 交付轨）
#
# 只装 JRE 与已构建产物：构建工具、源码、测试都不进交付镜像。
# 构建前提（宿主上先做，与开发态同一份产物）：
#   mvn -B -ntp -Dmaven.repo.local=<absolute-repo-cache-path> -DskipTests clean package
# Maven 在打包前构建 Vue UI 并放入 JAR 的 static/；宿主需 Node 22/npm 10。
# 依赖方向：本文件与 docker-compose.yml 只描述编排，不含任何业务规则。
FROM eclipse-temurin:21-jre

# 交付态固定时区与语言无关行为：时间一律 UTC（05 §总则：时间 ISO-8601 UTC）
ENV TZ=UTC \
    CANGSHU_DATA_ROOT=/data \
    CANGSHU_MIGRATION_DIR=/app/db/migration

WORKDIR /app
# 产物名由 pom 固定（artifactId-version.jar）；COPY 精确到文件，避免把整个 target/ 拖进镜像
COPY target/cangshu-0.1.0-SNAPSHOT.jar /app/cangshu.jar
# 启动核对必须读取与人工迁移同一份脚本；仅复制脚本，不在镜像启动时执行它们。
COPY db/migration /app/db/migration

# 数据根在容器内固定为 /data（07 §3 命名口径：宿主 cangshu-blobs → 容器 /data）
VOLUME ["/data"]
EXPOSE 8080

# 单写者与迁移只读核对已由应用启动门执行；失败退出码 2／3，此处不做任何降级兜底
ENTRYPOINT ["java", "-jar", "/app/cangshu.jar"]
