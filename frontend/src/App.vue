<script setup lang="ts">
import { computed, onMounted, ref } from 'vue'
import { api, canPreview, contentUrl, errorText, type Page, type Resource, type Upload } from './api'

type View = 'resources' | 'trash'
const view = ref<View>('resources')
const page = ref(1)
const size = 20
const data = ref<Page>({ items: [], total: 0, page: 1, size })
const loading = ref(false)
const listFailed = ref(false)
const busy = ref(false)
const name = ref('')
const tag = ref('')
const appliedName = ref('')
const appliedTag = ref('')
const selectedFile = ref<File | null>(null)
const fileInput = ref<HTMLInputElement | null>(null)
const detail = ref<Resource | null>(null)
const detailLoading = ref(false)
const previewId = ref<string | null>(null)
const message = ref('')
const error = ref('')
const confirmEmpty = ref(false)
let listVersion = 0
let detailVersion = 0
const pages = computed(() => Math.max(1, Math.ceil(data.value.total / size)))

function clearFeedback() { message.value = ''; error.value = '' }
function queryPath() {
  const params = new URLSearchParams({ page: String(page.value), size: String(size) })
  if (view.value === 'resources') {
    if (appliedName.value) params.set('name', appliedName.value)
    if (appliedTag.value) params.set('tag', appliedTag.value)
  }
  return `/api/resources${view.value === 'trash' ? '/trash' : ''}?${params}`
}
async function load() {
  const version = ++listVersion
  loading.value = true
  listFailed.value = false
  error.value = ''
  try {
    const result = await api<Page>(queryPath())
    if (version === listVersion) data.value = result
  } catch (cause) {
    if (version === listVersion) {
      listFailed.value = true
      error.value = `列表加载失败：${errorText(cause)}`
    }
  } finally {
    if (version === listVersion) loading.value = false
  }
}
function switchView(next: View) {
  if (view.value === next) return
  view.value = next; page.value = 1; data.value = { items: [], total: 0, page: 1, size }
  detail.value = null; detailLoading.value = false; previewId.value = null; confirmEmpty.value = false
  ++detailVersion; clearFeedback(); void load()
}
function search() {
  appliedName.value = name.value.trim(); appliedTag.value = tag.value.trim(); page.value = 1
  detail.value = null; detailLoading.value = false; previewId.value = null; ++detailVersion; void load()
}
function movePage(next: number) {
  if (next < 1 || next > pages.value || loading.value) return
  page.value = next; void load()
}
async function showDetail(item: Resource) {
  const version = ++detailVersion
  detail.value = null; previewId.value = null; detailLoading.value = true; clearFeedback()
  try {
    const result = await api<Resource>(`/api/resources/${encodeURIComponent(item.id)}`)
    if (version === detailVersion && view.value === 'resources') detail.value = result
  } catch (cause) {
    if (version === detailVersion) error.value = `详情加载失败：${errorText(cause)}`
  } finally {
    if (version === detailVersion) detailLoading.value = false
  }
}
async function upload() {
  if (busy.value || !selectedFile.value) return
  busy.value = true; clearFeedback()
  const form = new FormData(); form.append('file', selectedFile.value)
  try {
    const result = await api<Upload>('/api/resources', { method: 'POST', body: form })
    message.value = result.deduplicated ? '上传成功，已复用存储。' : '上传成功。'
    selectedFile.value = null
    if (fileInput.value) fileInput.value.value = ''
    if (view.value === 'resources') { page.value = 1; await load() }
  } catch (cause) { error.value = `上传失败：${errorText(cause)}` }
  finally { busy.value = false }
}
async function mutate(path: string, method: string, success: string, targetView?: View) {
  if (busy.value) return false
  busy.value = true; clearFeedback()
  try {
    await api<unknown>(path, { method })
    if (targetView) {
      view.value = targetView; page.value = 1
      data.value = { items: [], total: 0, page: 1, size }
      confirmEmpty.value = false
    }
    message.value = success; detail.value = null; detailLoading.value = false; previewId.value = null; ++detailVersion
    await load()
    if (data.value.items.length === 0 && page.value > 1) { page.value -= 1; await load() }
    return true
  } catch (cause) { error.value = errorText(cause); return false }
  finally { busy.value = false }
}
function remove(item: Resource) { void mutate(`/api/resources/${encodeURIComponent(item.id)}`, 'DELETE', '已移入回收站。') }
function restore(item: Resource) { void mutate(`/api/resources/${encodeURIComponent(item.id)}/restore`, 'POST', '已还原，可在资源列表查看。', 'resources') }
function askEmpty() { if (busy.value) return; clearFeedback(); confirmEmpty.value = true }
function cancelEmpty() { confirmEmpty.value = false }
async function emptyTrash() {
  if (busy.value || !confirmEmpty.value) return
  busy.value = true; clearFeedback()
  try {
    const result = await api<{ deletedCount: number }>('/api/resources/trash?confirm=true', { method: 'DELETE' })
    confirmEmpty.value = false; page.value = 1
    message.value = `已清空回收站，删除 ${result.deletedCount} 条资源。`
    await load()
  } catch (cause) { error.value = `清空失败：${errorText(cause)}` }
  finally { busy.value = false }
}
async function download(item: Resource) {
  if (busy.value) return
  busy.value = true; clearFeedback()
  const url = contentUrl(item.id)
  try {
    // HEAD validates the existing content endpoint without buffering file bytes.
    const response = await fetch(url, { method: 'HEAD' })
    if (!response.ok) throw new Error(`HTTP ${response.status}`)
    const link = document.createElement('a')
    link.href = url; link.download = item.name; document.body.append(link); link.click(); link.remove()
    message.value = '下载已交给浏览器；传输中断请查看浏览器下载记录。'
  } catch (cause) { error.value = `下载失败：${errorText(cause)}` }
  finally { busy.value = false }
}
function preview(item: Resource) {
  if (!canPreview(item.mimeType)) { error.value = '此类型不支持安全预览，请下载文件。'; return }
  clearFeedback(); previewId.value = item.id
}
const formatBytes = (value: number) => value < 1024 ? `${value} B` : `${(value / 1024).toFixed(1)} KB`
const formatTime = (value?: string) => value ? new Date(value).toLocaleString('zh-CN') : '—'
onMounted(load)
</script>

<template>
  <main class="shell">
    <header><div><h1>仓鼠</h1><p>个人资源管理</p></div><nav aria-label="主要页面"><button :aria-current="view === 'resources' ? 'page' : undefined" @click="switchView('resources')">资源列表</button><button :aria-current="view === 'trash' ? 'page' : undefined" @click="switchView('trash')">回收站</button></nav></header>
    <p v-if="message" class="notice success" role="status">{{ message }}</p>
    <p v-if="error" class="notice failure" role="alert">{{ error }}</p>

    <section v-if="view === 'resources'" class="panel" aria-label="上传资源">
      <h2>上传文件</h2><form @submit.prevent="upload"><input ref="fileInput" aria-label="选择文件" type="file" @change="selectedFile = ($event.target as HTMLInputElement).files?.[0] || null"><button type="submit" :disabled="busy || !selectedFile">{{ busy ? '处理中…' : '上传' }}</button></form>
      <p class="hint">一次上传一个文件；相同内容会创建新资源并复用存储。</p>
    </section>

    <section class="panel">
      <div class="section-head"><h2>{{ view === 'trash' ? '回收站' : '资源列表' }}</h2><button v-if="view === 'trash'" :disabled="busy || data.total === 0" class="danger" @click="askEmpty">清空回收站</button></div>
      <form v-if="view === 'resources'" class="search" @submit.prevent="search"><label>名称 <input v-model="name" placeholder="按文件名搜索"></label><label>标签 <input v-model="tag" placeholder="按标签过滤"></label><button type="submit">搜索</button></form>
      <p v-if="loading" role="status">正在加载…</p>
      <div v-else-if="listFailed" class="empty"><p>列表加载失败，请重试。</p><button @click="load">重试加载</button></div>
      <template v-else><p v-if="data.items.length === 0" class="empty">{{ view === 'trash' ? '回收站是空的。' : '暂无资源。可上传文件或更换搜索条件。' }}</p>
        <ul v-else class="items"><li v-for="item in data.items" :key="item.id"><div class="item-name">{{ item.name }}</div><div class="meta">{{ formatBytes(item.sizeBytes) }} · {{ formatTime(view === 'trash' ? item.deletedAt : item.createdAt) }}<span v-if="view === 'trash'"> · 到期 {{ formatTime(item.expireAt) }}</span></div><div class="actions"><template v-if="view === 'resources'"><button @click="showDetail(item)">详情</button><button :disabled="busy" @click="download(item)">下载</button><button :disabled="busy" @click="remove(item)">移入回收站</button></template><button v-else :disabled="busy" @click="restore(item)">还原</button></div></li></ul>
        <div class="pager"><button :disabled="page <= 1 || loading" @click="movePage(page - 1)">上一页</button><span>第 {{ page }} / {{ pages }} 页 · 共 {{ data.total }} 条</span><button :disabled="page >= pages || loading" @click="movePage(page + 1)">下一页</button></div>
      </template>
    </section>

    <section v-if="detailLoading || detail" class="panel detail" aria-label="资源详情"><h2>资源详情</h2><p v-if="detailLoading">正在加载详情…</p><template v-if="detail"><dl><dt>名称</dt><dd>{{ detail.name }}</dd><dt>大小</dt><dd>{{ formatBytes(detail.sizeBytes) }}</dd><dt>类型</dt><dd>{{ detail.mimeType }}</dd><dt>导入时间</dt><dd>{{ formatTime(detail.createdAt) }}</dd><dt>标签</dt><dd>{{ detail.tags.join('、') || '无' }}</dd><dt>Hash</dt><dd class="break">{{ detail.hash.algorithm }}: {{ detail.hash.digest }}</dd><dt>内容关联</dt><dd class="break">{{ detail.contentId || '—' }}</dd></dl><div class="actions"><button :disabled="busy" @click="download(detail)">下载</button><button v-if="canPreview(detail.mimeType)" @click="preview(detail)">基础预览</button></div></template></section>
    <section v-if="previewId" class="panel preview"><div class="section-head"><h2>基础预览</h2><button @click="previewId = null">关闭预览</button></div><iframe title="文件预览" sandbox="" referrerpolicy="no-referrer" :src="contentUrl(previewId, true)"></iframe></section>
    <div v-if="confirmEmpty" class="overlay"><section class="confirm" role="dialog" aria-modal="true" aria-labelledby="confirm-title"><h2 id="confirm-title">确认清空回收站？</h2><p>清空后无法还原这些资源。</p><div class="actions"><button :disabled="busy" @click="cancelEmpty">取消</button><button class="danger" :disabled="busy" @click="emptyTrash">{{ busy ? '清空中…' : '确认清空' }}</button></div></section></div>
  </main>
</template>
