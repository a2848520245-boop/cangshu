package com.cangshu.catalog.mapper;

import com.baomidou.mybatisplus.core.mapper.BaseMapper;
import com.cangshu.catalog.entity.LocationEntity;
import java.util.List;
import java.util.UUID;
import org.apache.ibatis.annotations.Param;
import org.apache.ibatis.annotations.Select;

/**
 * Location 表访问（MyBatis-Plus BaseMapper ＋ 对账所需的两条只读投影）。
 *
 * <p>两条投影都刻意**分批**：对账是每日作业，规模按 {@code 08 §1 ACC-G1} 的百万级元数据设计，
 * 因此不许把全表键或全表内容读进内存。孤儿判定用「一批键一次 IN 查询」，缺失判定用「按内容主键
 * 分页」。注意 {@code location.storage_key} **没有索引**（06 §5 只为 {@code content_id} 建了索引），
 * 分批 IN 会把扫描次数压到「批数」级而不是「文件数」级——这是本轮的既有约束，见证据页的偏离说明。
 */
public interface LocationMapper extends BaseMapper<LocationEntity> {

    /** 一批键里**已登记**的那些（孤儿判定：盘上有字节但这里查不到 → 孤儿）。 */
    @Select("""
            <script>
            SELECT storage_key FROM cangshu_m1.location
            WHERE storage_key IN
            <foreach collection="keys" item="key" open="(" separator="," close=")">#{key}</foreach>
            </script>
            """)
    List<String> findExistingKeys(@Param("keys") List<String> keys);

    /** 按内容主键分页取「内容身份 ＋ 位置键」（缺失字节判定）；{@code afterId} 为上一页末位主键。 */
    @Select("""
            SELECT c.id AS content_id, c.hash_algorithm, c.digest, c.size_bytes, c.status,
                   l.storage_key
            FROM cangshu_m1.content c
            LEFT JOIN cangshu_m1.location l ON l.content_id = c.id
            WHERE c.id > #{afterId}
            ORDER BY c.id
            LIMIT #{limit}
            """)
    List<ContentLocationRow> pageContentWithLocation(@Param("afterId") UUID afterId,
            @Param("limit") int limit);
}
