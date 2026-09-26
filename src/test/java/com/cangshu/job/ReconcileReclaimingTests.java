package com.cangshu.job;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertTrue;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.anyInt;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.when;

import com.cangshu.catalog.entity.ContentEntity;
import com.cangshu.catalog.mapper.ContentLocationRow;
import com.cangshu.catalog.mapper.ContentMapper;
import com.cangshu.catalog.mapper.LocationMapper;
import com.cangshu.config.WriterGate;
import com.cangshu.storage.FileStore;
import com.cangshu.storage.SegmentLockManager;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.security.MessageDigest;
import java.util.HexFormat;
import java.util.List;
import java.util.UUID;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.io.TempDir;

class ReconcileReclaimingTests {

    @TempDir
    Path root;

    @Test
    void gcPhaseOneResidueStaysInPlaceAndIsReported() throws Exception {
        Fixture fixture = fixture("GC phase one residue");
        ReconcileService.ReconcileReport report = reconcile(fixture, List.of(content(fixture, "RECLAIMING", null)));

        assertTrue(Files.isRegularFile(fixture.blob()));
        assertFalse(Files.exists(root.resolve("orphan").resolve(fixture.key())));
        assertEquals(0, report.orphanFound());
        assertEquals(0, report.orphanQuarantined());
        assertTrue(report.needsAttention());
        assertTrue(report.notes().stream().anyMatch(note -> note.contains("RECLAIMING") && note.contains("GC 续接")));
    }

    @Test
    void unownedBytesAreStillQuarantined() throws Exception {
        Fixture fixture = fixture("unowned bytes");
        ReconcileService.ReconcileReport report = reconcile(fixture, List.of());

        assertFalse(Files.exists(fixture.blob()));
        assertTrue(Files.isRegularFile(root.resolve("orphan").resolve(fixture.key())));
        assertEquals(1, report.orphanFound());
        assertEquals(1, report.orphanQuarantined());
    }

    @Test
    void reclaimedContentDoesNotClaimRemainingBytes() throws Exception {
        Fixture fixture = fixture("already reclaimed");
        ReconcileService.ReconcileReport report = reconcile(fixture, List.of(content(fixture, "RECLAIMED", null)));

        assertFalse(Files.exists(fixture.blob()));
        assertEquals(1, report.orphanQuarantined());
    }

    @Test
    void missingLocationForReadyContentIsPreservedAndReported() throws Exception {
        Fixture fixture = fixture("ready without location");
        ReconcileService.ReconcileReport report = reconcile(fixture, List.of(content(fixture, "READY", null)));

        assertTrue(Files.isRegularFile(fixture.blob()));
        assertEquals(0, report.orphanQuarantined());
        assertTrue(report.notes().stream().anyMatch(note -> note.contains("READY") && note.contains("位置行缺失")));
    }

    @Test
    void sizeMismatchStaysInPlaceForManualReview() throws Exception {
        Fixture fixture = fixture("size mismatch");
        ReconcileService.ReconcileReport report = reconcile(fixture,
                List.of(content(fixture, "RECLAIMING", fixture.bytes().length + 1L)));

        assertTrue(Files.isRegularFile(fixture.blob()));
        assertEquals(0, report.orphanQuarantined());
        assertTrue(report.notes().stream().anyMatch(note -> note.contains("大小与盘上字节不符")));
    }

    @Test
    void sameLengthBadBytesStayInPlaceForGcToCheck() throws Exception {
        Fixture fixture = fixture("original");
        Files.writeString(fixture.blob(), "tampered", StandardCharsets.UTF_8);
        ReconcileService.ReconcileReport report = reconcile(fixture,
                List.of(content(fixture, "RECLAIMING", null)));

        assertEquals("tampered", Files.readString(fixture.blob()));
        assertEquals(0, report.orphanQuarantined());
        assertTrue(report.needsAttention());
    }

    @Test
    void reclaimingWithBytesAlreadyDeletedIsReported() throws Exception {
        Fixture fixture = fixture("deleted by GC phase two");
        Files.delete(fixture.blob());
        ContentLocationRow row = reclaimingRow(fixture);
        ReconcileService.ReconcileReport report = reconcile(fixture,
                List.of(content(fixture, "RECLAIMING", null)), row);

        assertEquals(0, report.orphanFound());
        assertEquals(0, report.orphanQuarantined());
        assertTrue(report.notes().stream().anyMatch(note -> note.contains("RECLAIMING")
                && note.contains(row.getContentId().toString())));
    }

    @Test
    void reclaimingWithMultipleLocationsIsReportedAsAnomaly() throws Exception {
        Fixture fixture = fixture("multiple locations");
        Files.delete(fixture.blob());
        ContentLocationRow row = reclaimingRow(fixture);
        ReconcileService.ReconcileReport report = reconcile(fixture,
                List.of(content(fixture, "RECLAIMING", null)), row, List.of(row, row));

        assertEquals(0, report.orphanQuarantined());
        assertTrue(report.notes().stream().anyMatch(note -> note.contains("RECLAIMING")
                && note.contains("位置记录数异常=2")));
    }

    @Test
    void multipleIdentitiesStayInPlaceForManualReview() throws Exception {
        Fixture fixture = fixture("duplicate digest");
        ReconcileService.ReconcileReport report = reconcile(fixture,
                List.of(content(fixture, "RECLAIMING", null), content(fixture, "RECLAIMED", null)));

        assertTrue(Files.isRegularFile(fixture.blob()));
        assertEquals(0, report.orphanQuarantined());
        assertTrue(report.notes().stream().anyMatch(note -> note.contains("多条内容身份")));
    }

    private ReconcileService.ReconcileReport reconcile(Fixture fixture, List<ContentEntity> contents) {
        return reconcile(fixture, contents, null);
    }

    private ReconcileService.ReconcileReport reconcile(Fixture fixture, List<ContentEntity> contents,
            ContentLocationRow pageRow) {
        return reconcile(fixture, contents, pageRow, pageRow == null ? List.of() : List.of(pageRow));
    }

    private ReconcileService.ReconcileReport reconcile(Fixture fixture, List<ContentEntity> contents,
            ContentLocationRow pageRow, List<ContentLocationRow> currentRows) {
        ContentMapper contentMapper = mock(ContentMapper.class);
        LocationMapper locationMapper = mock(LocationMapper.class);
        when(locationMapper.findExistingKeys(any())).thenReturn(List.of());
        if (pageRow == null) {
            when(locationMapper.pageContentWithLocation(any(), anyInt())).thenReturn(List.of());
        } else {
            when(locationMapper.pageContentWithLocation(any(), anyInt()))
                    .thenReturn(List.of(pageRow), List.of());
            when(locationMapper.findContentLocation(pageRow.getContentId())).thenReturn(currentRows);
        }
        when(contentMapper.selectList(any())).thenReturn(contents);
        ReconcileService service = new ReconcileService(
                fixture.files(), contentMapper, locationMapper, new SegmentLockManager());
        return service.runOnce();
    }

    private static ContentLocationRow reclaimingRow(Fixture fixture) {
        ContentLocationRow row = new ContentLocationRow();
        row.setContentId(UUID.randomUUID());
        row.setHashAlgorithm("SHA-256");
        row.setDigest(fixture.digest());
        row.setSizeBytes((long) fixture.bytes().length);
        row.setStatus("RECLAIMING");
        return row;
    }

    private Fixture fixture(String text) throws Exception {
        byte[] bytes = text.getBytes(StandardCharsets.UTF_8);
        String digest = HexFormat.of().formatHex(MessageDigest.getInstance("SHA-256").digest(bytes));
        FileStore files = new FileStore(root, WriterGate.LOCK_FILE_NAME);
        String key = files.storageKey("SHA-256", digest);
        Path blob = files.blobPath(key);
        Files.createDirectories(blob.getParent());
        Files.write(blob, bytes);
        return new Fixture(files, key, blob, digest, bytes);
    }

    private static ContentEntity content(Fixture fixture, String status, Long sizeOverride) {
        ContentEntity content = new ContentEntity();
        content.setId(UUID.randomUUID());
        content.setHashAlgorithm("SHA-256");
        content.setDigest(fixture.digest());
        content.setSizeBytes(sizeOverride == null ? (long) fixture.bytes().length : sizeOverride);
        content.setStatus(status);
        return content;
    }

    private record Fixture(FileStore files, String key, Path blob, String digest, byte[] bytes) {
    }
}
