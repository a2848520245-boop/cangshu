package com.cangshu.catalog.mapper;

import com.baomidou.mybatisplus.core.mapper.BaseMapper;
import com.cangshu.catalog.entity.ResourceEntity;
import java.util.List;
import org.apache.ibatis.annotations.Select;

/**
 * Resource 表访问（MyBatis-Plus BaseMapper ＋ 回收站硬删所需的只读投影）。
 *
 * <p>两条投影的差别就是「到期」这个时间条件（04-架构与计划 §5 ②「触发＝到期或显式清空」）：
 * {@code findExpiredTrashRows} 只取 {@code expire_at <= now()}（走 {@code idx_resource_expire_at}），
 * {@code findAllTrashRows} 取回收站全部行，供「显式清空」使用。
 */
public interface ResourceMapper extends BaseMapper<ResourceEntity> {

    /** 到期硬删的候选行（无到期条件时的「显式清空」见下一条）。 */
    @Select("""
            SELECT r.id AS resource_id, r.content_id, c.hash_algorithm, c.digest
            FROM cangshu_m1.resource r
            JOIN cangshu_m1.content c ON c.id = r.content_id
            WHERE r.status = 'DELETED'
              AND r.expire_at <= now()
            ORDER BY r.id
            """)
    List<TrashRow> findExpiredTrashRows();

    /** 回收站全部行（供 {@code DELETE /api/resources/trash} 的显式清空）。 */
    @Select("""
            SELECT r.id AS resource_id, r.content_id, c.hash_algorithm, c.digest
            FROM cangshu_m1.resource r
            JOIN cangshu_m1.content c ON c.id = r.content_id
            WHERE r.status = 'DELETED'
            ORDER BY r.id
            """)
    List<TrashRow> findAllTrashRows();
}
