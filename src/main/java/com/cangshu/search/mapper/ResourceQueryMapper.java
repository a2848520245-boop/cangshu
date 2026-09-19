package com.cangshu.search.mapper;

import java.util.List;
import java.util.UUID;
import org.apache.ibatis.annotations.Param;
import org.apache.ibatis.annotations.Select;

/**
 * 资源查询（search 模块；《04-M1-架构与计划》§1：按文件名、标签、状态的查询，
 * M1 用数据库索引与 SQL 条件，不引入独立检索引擎）。只读，不写任何表。
 *
 * <p>口径（《05-M1-接口契约》§3.2／§3.3、《03-M1-SPEC》REQ-M1-04／05／06）：
 * 普通列表与详情对回收站不可见（{@code status <> 'DELETED'}）；
 * {@code name} 为文件名包含匹配（ILIKE，大小写不敏感，走 idx_resource_name_trgm）；
 * {@code tag} 为 jsonb 包含过滤（走 idx_resource_tags_jsonb）；排序固定 {@code id} DESC
 * （UUIDv7 时间有序 ≈ 新资源在前；主键索引反向扫描免排序、免全表扫描，分页锚点稳定）。
 */
public interface ResourceQueryMapper {

    @Select("""
            <script>
            SELECT r.id, r.name, r.size_bytes, r.mime_type, r.tags, r.status, r.created_at,
                   r.content_id, c.hash_algorithm, c.digest
            FROM cangshu_m1.resource r
            JOIN cangshu_m1.content c ON c.id = r.content_id
            <where>
              r.status &lt;&gt; 'DELETED'
              <if test="name != null and name != ''">
                AND r.name ILIKE ('%' || #{name} || '%')
              </if>
              <if test="tag != null and tag != ''">
                AND r.tags @&gt; to_jsonb(ARRAY[#{tag}])
              </if>
            </where>
            ORDER BY r.id DESC
            LIMIT #{limit} OFFSET #{offset}
            </script>
            """)
    List<ResourceSummaryRow> search(@Param("name") String name, @Param("tag") String tag,
            @Param("limit") int limit, @Param("offset") long offset);

    @Select("""
            <script>
            SELECT count(*)
            FROM cangshu_m1.resource r
            <where>
              r.status &lt;&gt; 'DELETED'
              <if test="name != null and name != ''">
                AND r.name ILIKE ('%' || #{name} || '%')
              </if>
              <if test="tag != null and tag != ''">
                AND r.tags @&gt; to_jsonb(ARRAY[#{tag}])
              </if>
            </where>
            </script>
            """)
    long countActive(@Param("name") String name, @Param("tag") String tag);

    @Select("""
            SELECT r.id, r.name, r.size_bytes, r.mime_type, r.tags, r.status, r.created_at,
                   r.content_id, c.hash_algorithm, c.digest
            FROM cangshu_m1.resource r
            JOIN cangshu_m1.content c ON c.id = r.content_id
            WHERE r.id = #{id}
              AND r.status <> 'DELETED'
            """)
    ResourceSummaryRow findActiveById(@Param("id") UUID id);
}
