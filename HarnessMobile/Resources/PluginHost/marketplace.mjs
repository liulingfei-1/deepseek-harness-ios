import { spawn } from 'node:child_process'
import { createHash, randomUUID } from 'node:crypto'
import {
  createWriteStream,
  existsSync,
} from 'node:fs'
import {
  cp,
  lstat,
  mkdir,
  open,
  opendir,
  readFile,
  realpath,
  rename,
  rm,
  stat,
  symlink,
  writeFile,
} from 'node:fs/promises'
import { createRequire } from 'node:module'
import https from 'node:https'
import path from 'node:path'
import { pathToFileURL } from 'node:url'
import { pipeline } from 'node:stream/promises'
import {
  composeEntries,
  loadOverlayPatches,
} from '@deepseek-ai/dsh-app-boot'
import yauzl from 'yauzl'

const MARKET_README_URLS = [
  'https://cdn.jsdelivr.net/gh/awesome-dsh-plugin/awesome-dsh-plugin@main/README.zh.md',
  'https://raw.githubusercontent.com/awesome-dsh-plugin/awesome-dsh-plugin/main/README.zh.md',
  'https://raw.githubusercontent.com/awesome-dsh-plugin/awesome-dsh-plugin/master/README.zh.md',
]
const ALLOWED_MARKET_HOSTS = new Set([
  'cdn.jsdelivr.net',
  'raw.githubusercontent.com',
])
const ALLOWED_DOWNLOAD_HOSTS = new Set([
  'github.com',
  'codeload.github.com',
  'raw.githubusercontent.com',
])
const ALLOWED_NPM_REGISTRIES = [
  'https://registry.npmmirror.com',
  'https://registry.npmjs.org',
]
const MARKET_CACHE_TTL_MS = 6 * 60 * 60 * 1000
const MAXIMUM_MARKET_BYTES = 4 * 1024 * 1024
const MAXIMUM_ZIP_BYTES = 64 * 1024 * 1024
const MAXIMUM_UNCOMPRESSED_BYTES = 256 * 1024 * 1024
const MAXIMUM_SINGLE_FILE_BYTES = 64 * 1024 * 1024
const MAXIMUM_ARCHIVE_FILES = 4096
const MAXIMUM_DEPENDENCIES = 128
const MAXIMUM_PROCESS_OUTPUT_BYTES = 1024 * 1024
const NPM_TIMEOUT_MS = 25 * 60 * 1000
const DOWNLOAD_TIMEOUT_MS = 60_000
const NATIVE_CLIENT_RUNTIME_VERSION = 2
const MAXIMUM_NATIVE_CLIENT_MANIFEST_BYTES = 256 * 1024
const MAXIMUM_NATIVE_CLIENT_CONTRIBUTIONS = 64
const MAXIMUM_NATIVE_CLIENT_ENDPOINTS = 64
const MAXIMUM_NATIVE_CLIENT_PERMISSIONS = 128
const MAXIMUM_NATIVE_CLIENT_ARGUMENT_BYTES = 16 * 1024
const MAXIMUM_NATIVE_CLIENT_CONTRIBUTION_BYTES = 32 * 1024
const MAXIMUM_NATIVE_CLIENT_ENDPOINT_RESULT_BYTES = 64 * 1024
const MAXIMUM_NATIVE_COMPILATION_SOURCE_BYTES = 180 * 1024
const MAXIMUM_NATIVE_COMPILATION_FILE_BYTES = 32 * 1024
const MAXIMUM_NATIVE_COMPILATION_FILES = 48
const MAXIMUM_PREPARED_NATIVE_SOURCES = 8
const PREPARED_NATIVE_SOURCE_TTL_MS = 30 * 60 * 1000
const NATIVE_CLIENT_ID_PATTERN = /^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$/
const NATIVE_CLIENT_COMMAND_PATTERN = /^[a-z][a-z0-9_-]{0,63}$/
const NATIVE_CLIENT_SERVICE_PATTERN = /^[A-Za-z0-9][A-Za-z0-9._/-]{0,127}$/
const NATIVE_COMPILATION_FAILURES = new Set([
  // These are compatibility/packaging failures, not trust failures. Keep
  // their bounded source snapshot available so the Swift NativeAgent compiler
  // can often replace the missing JS/Loader adapter with a declarative native
  // manifest instead of immediately falling back to iSH.
  'invalid-manifest',
  'invalid-patch',
  'missing-entrypoint',
  'missing-package',
  'npm-install-failed',
  'npm-pack-failed',
  'unsupported-entry',
  'unsupported-patch',
])
const NATIVE_COMPILATION_EXTENSIONS = new Set([
  '.cjs', '.js', '.json', '.jsx', '.md', '.mjs', '.ts', '.tsx', '.yaml', '.yml',
])
const NATIVE_COMPILATION_IGNORED_DIRECTORIES = new Set([
  // This is not a trust or compatibility filter.  A marketplace archive is
  // staged intact; only its private Git metadata is irrelevant to both the
  // mobile compiler and the iSH runtime.  In particular, published `lib/`,
  // `build/`, `dist/`, `coverage/`, and vendored `node_modules/` sources must
  // remain available for native-first analysis.
  '.git',
])

export class MarketplaceError extends Error {
  constructor(code, message, data) {
    super(message)
    this.name = 'MarketplaceError'
    this.code = code
    this.data = data
  }
}

function fail(code, message, data) {
  throw new MarketplaceError(code, message, data)
}

function normalizeText(value, maximumLength) {
  if (typeof value !== 'string') return undefined
  const normalized = value.replace(/\s+/g, ' ').trim()
  if (normalized.length === 0) return undefined
  return normalized.slice(0, maximumLength)
}

function publicText(value, maximumLength) {
  const normalized = normalizeText(value, maximumLength)
  if (normalized === undefined) return undefined
  return normalized
    .replace(/\bsk-[A-Za-z0-9_-]{12,}\b/g, '[credential-shaped text removed]')
    .replace(/\bBearer\s+[A-Za-z0-9._~-]{12,}\b/gi, 'Bearer [removed]')
}

function publicSourceCode(value) {
  return value
    .replace(/\bsk-[A-Za-z0-9_-]{12,}\b/g, '[credential-shaped text removed]')
    .replace(/\bBearer\s+[A-Za-z0-9._~-]{12,}\b/gi, 'Bearer [removed]')
}

function transportDiagnostic(error) {
  const value = error instanceof Error
    ? `${error.name}: ${error.message}`
    : String(error)
  return publicText(value, 600) ?? 'Unknown local transport failure.'
}

function downloadTransportError(subject, failures) {
  const transports = failures.map(({ transport, error }) => ({
    transport,
    message: transportDiagnostic(error),
  }))
  return new MarketplaceError(
    'download-failed',
    `${subject} failed through every on-device network transport.`,
    { transports },
  )
}

function isPlainObject(value) {
  if (value === null || typeof value !== 'object' || Array.isArray(value)) return false
  const prototype = Object.getPrototypeOf(value)
  return prototype === Object.prototype || prototype === null
}

function assertAllowedKeys(value, allowed, at) {
  if (!isPlainObject(value)) fail('invalid-native-client', `${at} must be an object.`)
  const unknown = Object.keys(value).find(key => !allowed.has(key))
  if (unknown !== undefined) {
    fail('invalid-native-client', `${at} contains unsupported field ${JSON.stringify(unknown)}.`)
  }
}

function nativeClientText(value, at, maximumLength, { optional = false } = {}) {
  if (value === undefined && optional) return undefined
  if (typeof value !== 'string') fail('invalid-native-client', `${at} must be a string.`)
  const normalized = value.replace(/\s+/g, ' ').trim()
  if (normalized.length === 0 || normalized.length > maximumLength) {
    fail('invalid-native-client', `${at} must contain 1-${maximumLength} characters.`)
  }
  return normalized
}

function nativeClientContent(value, at) {
  if (typeof value !== 'string' || value.trim().length === 0
    || Buffer.byteLength(value, 'utf8') > MAXIMUM_NATIVE_CLIENT_CONTRIBUTION_BYTES) {
    fail('invalid-native-client', `${at} must contain 1-${MAXIMUM_NATIVE_CLIENT_CONTRIBUTION_BYTES} UTF-8 bytes.`)
  }
  return value
}

function nativeClientID(value, at) {
  const id = nativeClientText(value, at, 128)
  if (!NATIVE_CLIENT_ID_PATTERN.test(id)) {
    fail('invalid-native-client', `${at} is not a supported native contribution id.`)
  }
  return id
}

function nativeClientOrder(value, at) {
  if (value === undefined) return 100
  if (!Number.isSafeInteger(value) || value < -10_000 || value > 10_000) {
    fail('invalid-native-client', `${at} must be an integer between -10000 and 10000.`)
  }
  return value
}

function nativeClientArray(value, at, maximumLength) {
  if (value === undefined) return []
  if (!Array.isArray(value) || value.length > maximumLength) {
    fail('invalid-native-client', `${at} must be an array with at most ${maximumLength} entries.`)
  }
  return value
}

function nativeClientCredentialKey(key) {
  const normalized = key.toLowerCase().replace(/[^a-z]/g, '')
  return ['apikey', 'authorization', 'accesstoken', 'refreshtoken', 'secretkey', 'clientsecret', 'password']
    .some(fragment => normalized.includes(fragment))
}

function assertNativeClientCredentialFree(value, at = '$', seen = new Set()) {
  if (typeof value === 'string') {
    if (/\bsk-[A-Za-z0-9_-]{12,}\b/.test(value)
      || /\bBearer\s+[A-Za-z0-9._~-]{12,}\b/i.test(value)) {
      fail('native-client-credentials', `${at} contains credential-shaped text.`)
    }
    return
  }
  if (value === null || typeof value !== 'object') return
  if (seen.has(value)) fail('invalid-native-client', `${at} contains a cycle.`)
  seen.add(value)
  try {
    if (Array.isArray(value)) {
      value.forEach((child, index) => assertNativeClientCredentialFree(child, `${at}[${index}]`, seen))
      return
    }
    for (const [key, child] of Object.entries(value)) {
      if (nativeClientCredentialKey(key)) {
        fail('native-client-credentials', `${at}.${key} uses a credential-like field name.`)
      }
      assertNativeClientCredentialFree(child, `${at}.${key}`, seen)
    }
  } finally {
    seen.delete(value)
  }
}

function assertJSONValue(value, at = '$', seen = new Set()) {
  if (value === null || typeof value === 'string' || typeof value === 'boolean') return
  if (typeof value === 'number') {
    if (!Number.isFinite(value)) fail('invalid-patch', `${at} contains a non-finite number.`)
    return
  }
  if (typeof value !== 'object') fail('invalid-patch', `${at} is not JSON-safe.`)
  if (seen.has(value)) fail('invalid-patch', `${at} contains a cycle.`)
  seen.add(value)
  try {
    if (Array.isArray(value)) {
      value.forEach((child, index) => assertJSONValue(child, `${at}[${index}]`, seen))
      return
    }
    if (!isPlainObject(value)) fail('invalid-patch', `${at} must be a plain JSON object.`)
    for (const [key, child] of Object.entries(value)) {
      if (child === undefined) fail('invalid-patch', `${at}.${key} is undefined.`)
      assertJSONValue(child, `${at}.${key}`, seen)
    }
  } finally {
    seen.delete(value)
  }
}

function safeRelativePath(value, label) {
  if (typeof value !== 'string' || value.length === 0 || value.length > 512) {
    fail('invalid-path', `${label} must be a non-empty relative path.`)
  }
  if (value.includes('\\') || value.includes('\0')) {
    fail('invalid-path', `${label} contains an unsupported path separator.`)
  }
  const normalized = path.posix.normalize(value.replace(/^\.\//, ''))
  const parts = normalized.split('/')
  if (normalized === '.' || normalized.startsWith('/') || /^[A-Za-z]:/.test(normalized)
    || parts.some(part => part === '' || part === '.' || part === '..')) {
    fail('invalid-path', `${label} must stay inside the plugin directory.`)
  }
  return normalized
}

function isContained(child, parent) {
  const relative = path.relative(parent, child)
  return relative === '' || (!relative.startsWith('..' + path.sep) && relative !== '..' && !path.isAbsolute(relative))
}

function npmPackageName(name) {
  return /^(?:@[a-z0-9][a-z0-9._-]*\/)?[a-z0-9][a-z0-9._-]*$/.test(name)
}

function packageNameFromSpecifier(specifier) {
  if (specifier.startsWith('@')) {
    const parts = specifier.split('/')
    return parts.length >= 2 ? `${parts[0]}/${parts[1]}` : undefined
  }
  return specifier.split('/')[0]
}

function validateBareSpecifier(specifier, label) {
  if (specifier === 'cordis:group') return undefined
  if (specifier.startsWith('cordis:')) {
    fail('unsupported-entry', `${label} uses unsupported Loader builtin ${JSON.stringify(specifier)}.`)
  }
  if (specifier.startsWith('.') || specifier.startsWith('/') || specifier.includes('\\')
    || specifier.includes('\0') || specifier.includes('://') || specifier.startsWith('node:')) {
    fail('unsupported-entry', `${label} must use an installed npm package name.`)
  }
  const packageName = packageNameFromSpecifier(specifier)
  if (packageName === undefined || !npmPackageName(packageName)) {
    fail('unsupported-entry', `${label} has an invalid npm package specifier.`)
  }
  const remainder = specifier.slice(packageName.length)
  if (remainder !== '' && (!remainder.startsWith('/') || remainder.split('/').slice(1).some(part => (
    part.length === 0 || part === '.' || part === '..'
  )))) {
    fail('unsupported-entry', `${label} has an invalid npm package subpath.`)
  }
  return packageName
}

function validateEntry(entry, knownIDs, at) {
  if (!isPlainObject(entry)) fail('invalid-patch', `${at} must be a Loader entry object.`)
  assertJSONValue(entry, at)
  if (typeof entry.id !== 'string' || !/^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$/.test(entry.id)) {
    fail('invalid-patch', `${at}.id must be a stable Loader id.`)
  }
  if (knownIDs.has(entry.id)) fail('invalid-patch', `Duplicate Loader entry id ${JSON.stringify(entry.id)}.`)
  if (typeof entry.name !== 'string' || entry.name.length === 0 || entry.name.length > 256) {
    fail('invalid-patch', `${at}.name must be a package specifier.`)
  }
  validateBareSpecifier(entry.name, `${at}.name`)
  const isGroup = entry.group === true || entry.name === 'cordis:group'
  if (entry.name === 'cordis:group' && entry.group !== true) {
    fail('invalid-patch', `${at} must set group: true for cordis:group.`)
  }
  if (isGroup && !Array.isArray(entry.config)) {
    fail('invalid-patch', `${at}.config must be an array for a Loader group.`)
  }
  knownIDs.set(entry.id, isGroup)
  if (isGroup) {
    entry.config.forEach((child, index) => validateEntry(child, knownIDs, `${at}.config[${index}]`))
  }
}

export function validateBundlePatches(patches) {
  if (!Array.isArray(patches) || patches.length === 0) {
    fail('invalid-patch', 'dsh.bundle.patch must insert at least one runtime entry.')
  }
  const knownIDs = new Map()
  patches.forEach((patch, index) => {
    const at = `patches[${index}]`
    if (!isPlainObject(patch)) fail('invalid-patch', `${at} must be a mapping.`)
    assertJSONValue(patch, at)
    if (patch.insert !== undefined) {
      if (!Array.isArray(patch.insert) || patch.insert.length === 0) {
        fail('invalid-patch', `${at}.insert must be a non-empty Loader entry array.`)
      }
      const allowedKeys = new Set(['id', 'insert'])
      if (Object.keys(patch).some(key => !allowedKeys.has(key))) {
        fail('invalid-patch', `${at} cannot combine insert with runtime overrides.`)
      }
      if (patch.id !== undefined && knownIDs.get(patch.id) !== true) {
        fail('unsupported-patch', `${at} targets a group that this bundle did not insert.`)
      }
      patch.insert.forEach((entry, entryIndex) => (
        validateEntry(entry, knownIDs, `${at}.insert[${entryIndex}]`)
      ))
      return
    }
    if (typeof patch.id !== 'string' || !knownIDs.has(patch.id)) {
      fail('unsupported-patch', `${at} targets a Desktop/base entry that is absent on mobile.`)
    }
  })

  const warnings = []
  const entries = composeEntries([patches], message => warnings.push(message))
  if (warnings.length > 0) {
    fail('unsupported-patch', `The bundle patch cannot be composed on the mobile runtime: ${warnings[0]}`)
  }
  const composedIDs = new Map()
  entries.forEach((entry, index) => validateEntry(entry, composedIDs, `entries[${index}]`))
  if (entries.length === 0) fail('invalid-patch', 'The bundle patch produced no runtime entries.')
  return entries
}

function packageSpecifiers(entries, packageName) {
  const specifiers = new Set()
  const collect = entry => {
    if (packageNameFromSpecifier(entry.name) === packageName) {
      specifiers.add(entry.name)
    }
    if (entry.group === true) entry.config.forEach(collect)
  }
  entries.forEach(collect)
  return specifiers
}

async function validateDeclaredPackageEntrypoint(
  directory,
  manifest,
  packageName,
  entries,
  knownSpecifiers,
) {
  const specifiers = knownSpecifiers ?? packageSpecifiers(entries, packageName)
  if (!specifiers.has(packageName) || manifest.main === undefined) return
  if (typeof manifest.main !== 'string' || manifest.main.length === 0) {
    fail('missing-entrypoint', `Package ${JSON.stringify(packageName)} has an invalid main entrypoint.`)
  }
  const entrypoint = path.resolve(directory, manifest.main)
  const entrypointInfo = isContained(entrypoint, directory)
    ? await stat(entrypoint).catch(() => undefined)
    : undefined
  if (entrypointInfo === undefined || !entrypointInfo.isFile()) {
    fail(
      'missing-entrypoint',
      `Runtime package ${JSON.stringify(packageName)} declares missing entrypoint ${JSON.stringify(manifest.main)}. The published package is missing its build output.`,
    )
  }
}

function cleanCategoryHeading(raw) {
  return raw
    .replace(/^#+\s*/, '')
    .replace(/^[^\p{L}\p{N}]+/u, '')
    .trim()
}

function catalogCompatibility(category) {
  if (category === '工具与能力' || category === '技能包'
    || category === '工作流与自动化' || category === '记忆') {
    return { compatibility: 'supported' }
  }
  return {
    compatibility: 'review',
    reason: '不会因分类拒绝安装：将先尝试原生编译，再在手机 iSH 中加载。桌面 Web Client 专属效果若没有手机等价实现，会在安装结果中明确说明。',
  }
}

function catalogNativeInstallStrategy(category) {
  // This is only a catalog hint. prepare-native performs the source-level
  // decision and Swift validation remains authoritative.
  return category === '主题与外观' || category === '桌面与外观'
    ? 'ish-required'
    : 'native-first'
}

export function parseMarketReadme(markdown) {
  if (typeof markdown !== 'string') fail('invalid-market', 'Market README must be text.')
  const items = []
  const seen = new Set()
  let category = '其他'
  for (const line of markdown.split(/\r?\n/)) {
    const heading = line.match(/^###\s+(.+?)\s*$/)
    if (heading !== null) {
      category = cleanCategoryHeading(heading[1]) || '其他'
      continue
    }
    const match = line.match(/^-\s+\[([^\]]+)]\((https:\/\/github\.com\/[^)]+)\)\s+(?:—|-)\s+(.+)$/)
    if (match === null) continue
    let parsed
    try {
      parsed = parseGitHubLocation(match[2])
    } catch {
      continue
    }
    if (seen.has(parsed.repositoryKey)) continue
    seen.add(parsed.repositoryKey)
    const compatibility = catalogCompatibility(category)
    items.push({
      id: parsed.repositoryKey,
      name: publicText(match[1], 160) ?? parsed.repositoryKey,
      repositoryURL: parsed.canonicalURL,
      repositoryKey: parsed.repositoryKey,
      description: publicText(match[3], 600) ?? '',
      category,
      compatibility: compatibility.compatibility,
      nativeInstallStrategy: catalogNativeInstallStrategy(category),
      ...(compatibility.reason === undefined ? {} : { unsupportedReason: compatibility.reason }),
    })
    if (items.length >= 1200) break
  }
  return items
}

function normalizedSubpath(value) {
  if (value === undefined || value === '' || value.toLowerCase() === 'readme') return undefined
  const decoded = decodeURIComponent(value).replace(/^\/+/, '')
  return safeRelativePath(decoded, 'GitHub subpath')
}

export function parseGitHubLocation(value) {
  if (typeof value !== 'string' || value.length === 0 || value.length > 2048) {
    fail('invalid-source', 'A GitHub repository URL is required.')
  }
  const expanded = /^[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+(?:#.+)?$/.test(value)
    ? `https://github.com/${value}`
    : value
  let url
  try {
    url = new URL(expanded)
  } catch {
    fail('invalid-source', 'The plugin source is not a valid GitHub URL.')
  }
  if (url.protocol !== 'https:' || url.hostname.toLowerCase() !== 'github.com'
    || url.username !== '' || url.password !== '' || url.search !== '') {
    fail('invalid-source', 'Only credential-free HTTPS github.com repository URLs are supported.')
  }
  const parts = url.pathname.split('/').filter(Boolean)
  if (parts.length < 2) fail('invalid-source', 'The GitHub URL must include an owner and repository.')
  const owner = parts[0]
  const repository = parts[1].replace(/\.git$/i, '')
  if (!/^[A-Za-z0-9_.-]{1,100}$/.test(owner) || !/^[A-Za-z0-9_.-]{1,100}$/.test(repository)) {
    fail('invalid-source', 'The GitHub owner or repository name is invalid.')
  }
  let ref
  let subpath
  if (parts.length > 2) {
    if (parts[2] !== 'tree' || parts.length < 4) {
      fail('invalid-source', 'Use a repository URL or a /tree/<branch>/<folder> GitHub URL.')
    }
    ref = decodeURIComponent(parts[3])
    if (!/^[A-Za-z0-9._-]{1,200}$/.test(ref)) {
      fail('invalid-source', 'GitHub branch names containing slashes require a repository-root URL.')
    }
    if (parts.length > 4) subpath = normalizedSubpath(parts.slice(4).join('/'))
  }
  if (subpath === undefined && url.hash.length > 1) {
    subpath = normalizedSubpath(url.hash.slice(1))
  }
  const repositoryRoot = `https://github.com/${owner}/${repository}`
  const canonicalURL = subpath === undefined
    ? repositoryRoot
    : `${repositoryRoot}/tree/${encodeURIComponent(ref ?? 'HEAD')}/${subpath}`
  const repositoryKey = `${owner.toLowerCase()}/${repository.toLowerCase()}${subpath === undefined ? '' : `#${subpath.toLowerCase()}`}`
  const archiveRef = ref === undefined ? 'HEAD' : encodeURIComponent(ref)
  return {
    owner,
    repository,
    ref,
    subpath,
    repositoryRoot,
    repositoryKey,
    canonicalURL,
    // Download directly from codeload rather than relying on github.com to
    // redirect. This gives the iSH wget fallback a fixed, approved HTTPS host.
    archiveURL: `https://codeload.github.com/${owner}/${repository}/zip/${archiveRef}`,
  }
}

export function validateArchiveEntryName(fileName) {
  if (typeof fileName !== 'string' || fileName.length === 0 || fileName.length > 2048
    || fileName.includes('\\') || fileName.includes('\0') || fileName.startsWith('/')
    || /^[A-Za-z]:/.test(fileName)) {
    fail('invalid-zip', 'The ZIP contains an unsafe filename.')
  }
  const trimmed = fileName.endsWith('/') ? fileName.slice(0, -1) : fileName
  const parts = trimmed.split('/')
  if (parts.some(part => part === '' || part === '.' || part === '..')) {
    fail('invalid-zip', `Unsafe ZIP path: ${JSON.stringify(fileName)}.`)
  }
  return parts
}

function openZip(zipPath) {
  return new Promise((resolve, reject) => {
    yauzl.open(zipPath, {
      autoClose: true,
      lazyEntries: true,
      strictFileNames: true,
      validateEntrySizes: true,
    }, (error, zipFile) => {
      if (error !== null) reject(error)
      else resolve(zipFile)
    })
  })
}

async function inspectArchive(zipPath) {
  const zipFile = await openZip(zipPath)
  return await new Promise((resolve, reject) => {
    const entries = []
    let totalBytes = 0
    let fileCount = 0
    const abort = (error) => {
      try { zipFile.close() } catch {}
      reject(error)
    }
    zipFile.on('error', abort)
    zipFile.on('entry', (entry) => {
      try {
        validateArchiveEntryName(entry.fileName)
        if ((entry.generalPurposeBitFlag & 0x1) !== 0) {
          fail('invalid-zip', 'Encrypted ZIP entries are not supported.')
        }
        const isDirectory = entry.fileName.endsWith('/')
        const unixMode = (entry.externalFileAttributes >>> 16) & 0xffff
        const fileType = unixMode & 0o170000
        const isSymbolicLink = fileType === 0o120000
        if (isSymbolicLink && isDirectory) {
          fail('invalid-zip', 'A ZIP symbolic link cannot also be a directory entry.')
        }
        if (fileType !== 0 && fileType !== 0o100000 && fileType !== 0o040000 && !isSymbolicLink) {
          fail('invalid-zip', 'The ZIP contains a non-regular filesystem entry.')
        }
        if (!isDirectory) {
          fileCount += 1
          totalBytes += entry.uncompressedSize
          if (fileCount > MAXIMUM_ARCHIVE_FILES) fail('zip-limit', 'The ZIP contains too many files.')
          if (entry.uncompressedSize > MAXIMUM_SINGLE_FILE_BYTES) {
            fail('zip-limit', `ZIP entry ${JSON.stringify(entry.fileName)} is too large.`)
          }
          if (isSymbolicLink && entry.uncompressedSize > 2_048) {
            fail('invalid-zip', `ZIP symbolic link ${JSON.stringify(entry.fileName)} has an invalid target.`)
          }
          if (totalBytes > MAXIMUM_UNCOMPRESSED_BYTES) {
            fail('zip-limit', 'The ZIP expands beyond the on-device size limit.')
          }
        }
        entries.push({
          fileName: entry.fileName,
          isDirectory,
          isSymbolicLink,
          compressedSize: entry.compressedSize,
          uncompressedSize: entry.uncompressedSize,
        })
        zipFile.readEntry()
      } catch (error) {
        abort(error)
      }
    })
    zipFile.on('end', () => resolve(entries))
    zipFile.readEntry()
  })
}

function archiveExtractionPlan(entries, requestedSubpath) {
  const files = entries.filter(entry => !entry.isDirectory)
  if (files.length === 0) fail('invalid-zip', 'The ZIP contains no files.')
  const split = entries.map(entry => ({ entry, parts: validateArchiveEntryName(entry.fileName) }))
  const fileParts = split.filter(item => !item.entry.isDirectory).map(item => item.parts)
  const commonRoot = fileParts.every(parts => parts.length > 1 && parts[0] === fileParts[0][0])
    ? fileParts[0][0]
    : undefined
  const requestedParts = requestedSubpath === undefined ? [] : safeRelativePath(
    requestedSubpath,
    'GitHub subpath',
  ).split('/')
  const plan = new Map()
  const selectedNames = new Set()
  let selectedFileCount = 0
  for (const { entry, parts: rawParts } of split) {
    let parts = rawParts
    if (commonRoot !== undefined && parts[0] === commonRoot) parts = parts.slice(1)
    if (requestedParts.length > 0) {
      if (parts.length < requestedParts.length
        || requestedParts.some((part, index) => parts[index] !== part)) continue
      parts = parts.slice(requestedParts.length)
    }
    if (parts.length === 0) continue
    if (parts[0] === '__MACOSX' || parts.at(-1) === '.DS_Store') continue
    // Do not reject vendored JavaScript dependencies merely because they are
    // under `node_modules`. Some marketplace plugins publish a self-contained
    // runtime or omit dependency metadata. The archive-size, file-count,
    // traversal, symlink and later iSH-native-addon checks still apply.
    const relativePath = parts.join('/')
    const folded = relativePath.toLowerCase()
    if (selectedNames.has(folded)) fail('invalid-zip', `Duplicate or case-colliding ZIP path ${relativePath}.`)
    selectedNames.add(folded)
    plan.set(entry.fileName, {
      relativePath,
      isDirectory: entry.isDirectory,
      isSymbolicLink: entry.isSymbolicLink === true,
    })
    if (!entry.isDirectory) selectedFileCount += 1
  }
  if (selectedFileCount === 0) {
    fail('invalid-source', 'The selected GitHub folder contains no files.')
  }
  return plan
}

async function extractArchive(zipPath, destination, plan) {
  await mkdir(destination, { recursive: true, mode: 0o700 })
  const zipFile = await openZip(zipPath)
  return await new Promise((resolve, reject) => {
    let settled = false
    const symbolicLinks = []
    const finish = (error) => {
      if (settled) return
      settled = true
      try { zipFile.close() } catch {}
      if (error === undefined) resolve()
      else reject(error)
    }
    zipFile.on('error', finish)
    zipFile.on('end', () => {
      materializeArchiveSymbolicLinks(destination, plan, symbolicLinks)
        .then(() => finish(), finish)
    })
    zipFile.on('entry', (entry) => {
      const planned = plan.get(entry.fileName)
      if (planned === undefined) {
        zipFile.readEntry()
        return
      }
      const operation = async () => {
        const { relativePath } = planned
        const target = path.join(destination, ...relativePath.split('/'))
        if (!isContained(target, destination)) fail('invalid-zip', 'The ZIP path escaped the staging directory.')
        if (planned.isDirectory) {
          await mkdir(target, { recursive: true, mode: 0o700 })
          return
        }
        const readStream = await new Promise((resolveStream, rejectStream) => {
          zipFile.openReadStream(entry, (error, stream) => {
            if (error !== null) rejectStream(error)
            else resolveStream(stream)
          })
        })
        if (planned.isSymbolicLink) {
          const chunks = []
          let byteCount = 0
          for await (const chunk of readStream) {
            byteCount += chunk.length
            if (byteCount > 2_048) {
              fail('invalid-zip', `ZIP symbolic link ${JSON.stringify(entry.fileName)} has an invalid target.`)
            }
            chunks.push(chunk)
          }
          symbolicLinks.push({
            relativePath,
            target: Buffer.concat(chunks).toString('utf8'),
          })
          return
        }
        await mkdir(path.dirname(target), { recursive: true, mode: 0o700 })
        await pipeline(readStream, createWriteStream(target, { flags: 'wx', mode: 0o600 }))
      }
      operation().then(() => zipFile.readEntry(), finish)
    })
    zipFile.readEntry()
  })
}

/// GitHub source archives sometimes contain repository-internal symbolic links
/// (for example AGENTS.md -> CLAUDE.md). Preserve the content contract without
/// creating a filesystem link in the mobile workspace: resolve only targets
/// selected from the same archive, then copy them as ordinary files/directories.
/// Absolute paths, archive escapes, missing targets, and cycles remain rejected.
async function materializeArchiveSymbolicLinks(destination, plan, symbolicLinks) {
  if (symbolicLinks.length === 0) return
  const selectedPaths = new Set([...plan.values()].map(value => value.relativePath))
  const linksByPath = new Map(symbolicLinks.map(link => [link.relativePath, link]))
  const resolving = new Set()
  const resolved = new Set()

  const targetIsSelected = target => selectedPaths.has(target)
    || [...selectedPaths].some(candidate => candidate.startsWith(`${target}/`))

  const resolveLink = async (relativePath) => {
    if (resolved.has(relativePath)) return
    if (resolving.has(relativePath)) {
      fail('invalid-zip', `ZIP symbolic link cycle detected at ${JSON.stringify(relativePath)}.`)
    }
    const link = linksByPath.get(relativePath)
    if (link === undefined) return
    resolving.add(relativePath)
    try {
      const rawTarget = link.target
      if (rawTarget.length === 0 || rawTarget.includes('\0') || rawTarget.includes('\\')
        || path.posix.isAbsolute(rawTarget) || /^[A-Za-z]:/.test(rawTarget)) {
        fail('invalid-zip', `ZIP symbolic link ${JSON.stringify(relativePath)} has an unsafe target.`)
      }
      const targetPath = path.posix.normalize(
        path.posix.join(path.posix.dirname(relativePath), rawTarget),
      )
      if (targetPath === '.' || targetPath === '..' || targetPath.startsWith('../')
        || !targetIsSelected(targetPath)) {
        fail('invalid-zip', `ZIP symbolic link ${JSON.stringify(relativePath)} escapes the selected source.`)
      }
      if (linksByPath.has(targetPath)) await resolveLink(targetPath)

      const source = path.join(destination, ...targetPath.split('/'))
      const target = path.join(destination, ...relativePath.split('/'))
      if (!isContained(source, destination) || !isContained(target, destination)) {
        fail('invalid-zip', 'A ZIP symbolic link escaped the staging directory.')
      }
      const sourceInfo = await lstat(source).catch(() => undefined)
      if (sourceInfo === undefined || (!sourceInfo.isFile() && !sourceInfo.isDirectory())
        || sourceInfo.isSymbolicLink()) {
        fail('invalid-zip', `ZIP symbolic link ${JSON.stringify(relativePath)} does not target a regular archive entry.`)
      }
      if (await lstat(target).then(() => true, () => false)) {
        fail('invalid-zip', `ZIP symbolic link destination ${JSON.stringify(relativePath)} already exists.`)
      }
      await mkdir(path.dirname(target), { recursive: true, mode: 0o700 })
      await cp(source, target, { recursive: sourceInfo.isDirectory(), force: false, errorOnExist: true })
      resolved.add(relativePath)
    } finally {
      resolving.delete(relativePath)
    }
  }

  for (const { relativePath } of symbolicLinks) await resolveLink(relativePath)
}

async function readJSONFile(file, maximumBytes = 1024 * 1024) {
  const info = await stat(file)
  if (!info.isFile() || info.size > maximumBytes) fail('invalid-manifest', `${file} is not a bounded regular file.`)
  try {
    return JSON.parse(await readFile(file, 'utf8'))
  } catch (error) {
    fail('invalid-manifest', `Failed to parse ${file}: ${error instanceof Error ? error.message : String(error)}`)
  }
}

async function packageCandidates(root, depth = 0, output = []) {
  if (depth > 6 || output.length > 64) return output
  const directory = await opendir(root)
  for await (const entry of directory) {
    // Dependency manifests are not competing marketplace bundle roots. This
    // affects only bundle-root discovery; it does not discard their files from
    // the staged archive or native compiler snapshot.
    if (entry.name === 'node_modules' || entry.name === '.git') continue
    const target = path.join(root, entry.name)
    const info = await lstat(target)
    if (info.isSymbolicLink()) fail('invalid-zip', 'Plugin staging unexpectedly contains a symbolic link.')
    if (info.isDirectory()) {
      await packageCandidates(target, depth + 1, output)
    } else if (entry.name === 'package.json' && info.isFile()) {
      output.push(target)
    }
  }
  return output
}

function nativeCompilationPriority(relativePath) {
  const normalized = relativePath.toLowerCase()
  if (normalized === 'package.json') return 1000
  if (normalized.endsWith('/package.json')) return 950
  if (normalized.endsWith('cordis.patch.yml') || normalized.endsWith('cordis.patch.yaml')) return 900
  if (normalized.endsWith('src/index.ts') || normalized.endsWith('src/index.js')) return 850
  if (normalized.includes('/tool.') || normalized.includes('/tools.')) return 800
  if (normalized.includes('/service.') || normalized.includes('/store.')) return 750
  if (normalized.startsWith('src/') || normalized.includes('/src/')) return 700
  if (normalized.startsWith('readme')) return 300
  // Vendored sources are retained, but are considered after the plugin's own
  // entrypoint and source tree when the bounded compiler window is full.
  if (normalized.startsWith('node_modules/')) return 50
  return 100
}

async function nativeCompilationFiles(root, relativeRoot = '', output = []) {
  if (output.length >= 512) return output
  const directory = await opendir(path.join(root, relativeRoot))
  const entries = []
  for await (const entry of directory) entries.push(entry)
  // Visit the plugin package before its vendored dependency tree so a large
  // `node_modules` cannot hide the actual plugin entrypoint behind the
  // diagnostic file ceiling. This is ordering, not filtering: every allowed
  // source directory is still traversed while capacity remains.
  entries.sort((left, right) => {
    const leftDependency = left.name === 'node_modules' ? 1 : 0
    const rightDependency = right.name === 'node_modules' ? 1 : 0
    return leftDependency - rightDependency || left.name.localeCompare(right.name)
  })
  for (const entry of entries) {
    if (NATIVE_COMPILATION_IGNORED_DIRECTORIES.has(entry.name)) continue
    const relativePath = relativeRoot === '' ? entry.name : `${relativeRoot}/${entry.name}`
    const target = path.join(root, ...relativePath.split('/'))
    const info = await lstat(target)
    if (info.isSymbolicLink()) continue
    if (info.isDirectory()) {
      await nativeCompilationFiles(root, relativePath, output)
      continue
    }
    if (!info.isFile() || !NATIVE_COMPILATION_EXTENSIONS.has(path.extname(entry.name).toLowerCase())) continue
    output.push({ relativePath, size: info.size })
  }
  return output
}

async function makeNativeCompilationCandidate(root, publicSource, failureReason) {
  const candidates = await nativeCompilationFiles(root)
  candidates.sort((left, right) => {
    const priority = nativeCompilationPriority(right.relativePath)
      - nativeCompilationPriority(left.relativePath)
    return priority === 0 ? left.relativePath.localeCompare(right.relativePath) : priority
  })

  const files = []
  let totalBytes = 0
  for (const candidate of candidates) {
    if (files.length >= MAXIMUM_NATIVE_COMPILATION_FILES
      || totalBytes >= MAXIMUM_NATIVE_COMPILATION_SOURCE_BYTES) break
    const remaining = MAXIMUM_NATIVE_COMPILATION_SOURCE_BYTES - totalBytes
    const maximumBytes = Math.min(MAXIMUM_NATIVE_COMPILATION_FILE_BYTES, remaining)
    if (maximumBytes <= 0) break
    const raw = await readFile(path.join(root, ...candidate.relativePath.split('/')))
    const bounded = raw.subarray(0, maximumBytes)
    const content = publicSourceCode(bounded.toString('utf8'))
    const contentBytes = Buffer.byteLength(content, 'utf8')
    if (contentBytes === 0) continue
    files.push({
      path: candidate.relativePath,
      content,
      truncated: candidate.size > bounded.length,
    })
    totalBytes += contentBytes
  }
  if (files.length === 0) return undefined

  let packageName
  let version
  let description
  for (const packageJSONPath of await packageCandidates(root)) {
    try {
      const manifest = await readJSONFile(packageJSONPath)
      if (!isPlainObject(manifest?.dsh?.bundle)) continue
      packageName = publicText(manifest.name, 214)
      version = publicText(manifest.version, 80)
      description = publicText(manifest.description, 600)
      break
    } catch {
      // The compilation snapshot is best-effort diagnostic input. The normal
      // marketplace error remains authoritative when metadata is malformed.
    }
  }
  const digest = createHash('sha256')
  for (const file of files) {
    digest.update(file.path)
    digest.update('\0')
    digest.update(file.content)
    digest.update('\0')
  }
  return {
    schemaVersion: 1,
    failureReason,
    sourceDigest: digest.digest('hex'),
    source: structuredClone(publicSource),
    ...(packageName === undefined ? {} : { packageName }),
    ...(version === undefined ? {} : { version }),
    ...(description === undefined ? {} : { description }),
    files,
  }
}

async function attachNativeCompilationCandidate(error, root, publicSource) {
  if (!(error instanceof MarketplaceError) || !NATIVE_COMPILATION_FAILURES.has(error.code)) {
    return
  }
  const nativeCandidate = await makeNativeCompilationCandidate(
    root,
    publicSource,
    error.code,
  ).catch(() => undefined)
  if (nativeCandidate !== undefined) {
    error.data = { ...(error.data ?? {}), nativeCandidate }
  }
}

function validateDependencyMap(manifest, field) {
  const dependencies = manifest[field]
  if (dependencies === undefined) return
  if (!isPlainObject(dependencies)) fail('invalid-manifest', `${field} must be an object.`)
  const entries = Object.entries(dependencies)
  if (entries.length > MAXIMUM_DEPENDENCIES) fail('dependency-limit', `${field} declares too many packages.`)
  for (const [name, specification] of entries) {
    if (!npmPackageName(name) || typeof specification !== 'string' || specification.length === 0
      || specification.length > 300) {
      fail('invalid-manifest', `${field} contains an invalid dependency declaration.`)
    }
    if (/^(?:file:|link:|workspace:|portal:|git(?:\+|:)|https?:|github:|\.\.?\/|\/)/i.test(specification)) {
      fail('unsafe-dependency', `${field}.${name} uses a non-registry dependency source.`)
    }
  }
}

function sanitizedPluginID(packageName) {
  const normalized = packageName
    .replace(/^@/, '')
    .replace('/', '--')
    .toLowerCase()
    .replace(/[^a-z0-9_-]+/g, '-')
    .replace(/^-+|-+$/g, '')
  if (!/^[a-z0-9][a-z0-9_-]{0,79}$/.test(normalized)) {
    fail('invalid-manifest', `Package name ${JSON.stringify(packageName)} cannot become a mobile plugin id.`)
  }
  return normalized
}

function loaderEntryKinds(entries) {
  const result = new Map()
  const visit = (entry) => {
    result.set(entry.id, entry.group === true || entry.name === 'cordis:group')
    if (entry.group === true) entry.config.forEach(visit)
  }
  entries.forEach(visit)
  return result
}

function validateNativeClientEndpoint(raw, index, entryKinds) {
  const at = `native-client.json.endpoints[${index}]`
  assertAllowedKeys(raw, new Set([
    'id',
    'kind',
    'entry',
    'service',
    'method',
    'readOnly',
  ]), at)
  const id = nativeClientID(raw.id, `${at}.id`)
  if (raw.kind !== 'hostService') {
    fail('invalid-native-client', `${at}.kind must be "hostService".`)
  }
  const entry = nativeClientID(raw.entry, `${at}.entry`)
  if (!entryKinds.has(entry) || entryKinds.get(entry) === true) {
    fail('invalid-native-client', `${at}.entry must reference a non-group Loader entry in this bundle.`)
  }
  const service = nativeClientText(raw.service, `${at}.service`, 128)
  const method = nativeClientText(raw.method, `${at}.method`, 128)
  if (!NATIVE_CLIENT_SERVICE_PATTERN.test(service) || !NATIVE_CLIENT_SERVICE_PATTERN.test(method)) {
    fail('invalid-native-client', `${at} uses an unsupported service or method name.`)
  }
  if (raw.readOnly !== true) {
    fail('invalid-native-client', `${at}.readOnly must be true.`)
  }
  return { id, kind: 'hostService', entry, service, method, readOnly: true }
}

function validateNativeClientInspector(raw, index) {
  const at = `native-client.json.contributions.inspectors[${index}]`
  assertAllowedKeys(raw, new Set([
    'id',
    'title',
    'description',
    'order',
    'renderer',
    'endpoint',
  ]), at)
  const renderer = raw.renderer ?? 'keyValue'
  if (renderer !== 'keyValue' && renderer !== 'markdown') {
    fail('invalid-native-client', `${at}.renderer must be "keyValue" or "markdown".`)
  }
  return {
    id: nativeClientID(raw.id, `${at}.id`),
    title: nativeClientText(raw.title, `${at}.title`, 120),
    ...(raw.description === undefined ? {} : {
      description: nativeClientText(raw.description, `${at}.description`, 600),
    }),
    order: nativeClientOrder(raw.order, `${at}.order`),
    renderer,
    endpoint: nativeClientID(raw.endpoint, `${at}.endpoint`),
  }
}

function validateNativeClientSettingsLink(raw, index) {
  const at = `native-client.json.contributions.settings[${index}]`
  assertAllowedKeys(raw, new Set(['id', 'title', 'namespace', 'order']), at)
  const namespace = nativeClientText(raw.namespace, `${at}.namespace`, 128)
  if (!NATIVE_CLIENT_SERVICE_PATTERN.test(namespace)) {
    fail('invalid-native-client', `${at}.namespace is not supported.`)
  }
  return {
    id: nativeClientID(raw.id, `${at}.id`),
    title: nativeClientText(raw.title, `${at}.title`, 120),
    namespace,
    order: nativeClientOrder(raw.order, `${at}.order`),
  }
}

function validateNativeClientCommand(raw, index) {
  const at = `native-client.json.contributions.commands[${index}]`
  assertAllowedKeys(raw, new Set([
    'name',
    'description',
    'inputHint',
    'inputImages',
    'images',
    'order',
    'action',
  ]), at)
  const name = nativeClientText(raw.name, `${at}.name`, 64)
  if (!NATIVE_CLIENT_COMMAND_PATTERN.test(name)) {
    fail('invalid-native-client', `${at}.name must match [a-z][a-z0-9_-]*.`)
  }
  assertAllowedKeys(raw.action, new Set(['kind', 'name', 'arguments', 'inputKey']), `${at}.action`)
  if (raw.action.kind !== 'hostTool') {
    fail('invalid-native-client', `${at}.action.kind must be "hostTool".`)
  }
  const toolName = nativeClientText(raw.action.name, `${at}.action.name`, 128)
  if (!NATIVE_CLIENT_SERVICE_PATTERN.test(toolName)) {
    fail('invalid-native-client', `${at}.action.name is not supported.`)
  }
  const inputHint = raw.inputHint === undefined
    ? undefined
    : nativeClientText(raw.inputHint, `${at}.inputHint`, 120)
  const inputImagesRaw = raw.inputImages === undefined ? raw.images : raw.inputImages
  const inputImages = inputImagesRaw === undefined
    ? false
    : inputImagesRaw
  if (typeof inputImages !== 'boolean') {
    fail('invalid-native-client', `${at}.inputImages must be a boolean.`)
  }
  const inputKey = raw.action.inputKey === undefined
    ? undefined
    : nativeClientText(raw.action.inputKey, `${at}.action.inputKey`, 64)
  if ((inputHint === undefined) !== (inputKey === undefined)) {
    fail('invalid-native-client', `${at} must declare inputHint and action.inputKey together.`)
  }
  if (inputKey !== undefined
    && (!NATIVE_CLIENT_ID_PATTERN.test(inputKey) || nativeClientCredentialKey(inputKey))) {
    fail('invalid-native-client', `${at}.action.inputKey is not supported.`)
  }
  const args = raw.action.arguments ?? {}
  if (!isPlainObject(args)) {
    fail('invalid-native-client', `${at}.action.arguments must be a JSON object.`)
  }
  assertJSONValue(args, `${at}.action.arguments`)
  assertNativeClientCredentialFree(args, `${at}.action.arguments`)
  if (Buffer.byteLength(JSON.stringify(args), 'utf8') > MAXIMUM_NATIVE_CLIENT_ARGUMENT_BYTES) {
    fail('invalid-native-client', `${at}.action.arguments is too large.`)
  }
  return {
    name,
    description: nativeClientText(raw.description, `${at}.description`, 600),
    ...(inputHint === undefined ? {} : { inputHint }),
    ...(inputImages ? { inputImages: true } : {}),
    order: nativeClientOrder(raw.order, `${at}.order`),
    action: {
      kind: 'hostTool',
      name: toolName,
      arguments: structuredClone(args),
      ...(inputKey === undefined ? {} : { inputKey }),
    },
  }
}

function validateNativeClientCard(raw, index) {
  const at = `native-client.json.contributions.cards[${index}]`
  assertAllowedKeys(raw, new Set([
    'id',
    'title',
    'description',
    'order',
    'renderer',
    'value',
  ]), at)
  const renderer = raw.renderer ?? 'keyValue'
  if (renderer !== 'keyValue' && renderer !== 'markdown') {
    fail('invalid-native-client', `${at}.renderer must be "keyValue" or "markdown".`)
  }
  assertJSONValue(raw.value, `${at}.value`)
  assertNativeClientCredentialFree(raw.value, `${at}.value`)
  if (Buffer.byteLength(JSON.stringify(raw.value), 'utf8') > MAXIMUM_NATIVE_CLIENT_CONTRIBUTION_BYTES) {
    fail('invalid-native-client', `${at}.value is too large.`)
  }
  return {
    id: nativeClientID(raw.id, `${at}.id`),
    title: nativeClientText(raw.title, `${at}.title`, 120),
    ...(raw.description === undefined ? {} : {
      description: nativeClientText(raw.description, `${at}.description`, 600),
    }),
    order: nativeClientOrder(raw.order, `${at}.order`),
    renderer,
    value: structuredClone(raw.value),
  }
}

function validateNativeClientReference(raw, index) {
  const at = `native-client.json.contributions.references[${index}]`
  assertAllowedKeys(raw, new Set(['id', 'label', 'description', 'order', 'content']), at)
  const content = nativeClientContent(raw.content, `${at}.content`)
  assertNativeClientCredentialFree(content, `${at}.content`)
  return {
    id: nativeClientID(raw.id, `${at}.id`),
    label: nativeClientText(raw.label, `${at}.label`, 120),
    ...(raw.description === undefined ? {} : {
      description: nativeClientText(raw.description, `${at}.description`, 600),
    }),
    order: nativeClientOrder(raw.order, `${at}.order`),
    content,
  }
}

function validateNativeClientPermissions(rawPermissions, requiredPermissions) {
  const permissions = nativeClientArray(
    rawPermissions,
    'native-client.json.permissions',
    MAXIMUM_NATIVE_CLIENT_PERMISSIONS,
  ).map((value, index) => nativeClientText(
    value,
    `native-client.json.permissions[${index}]`,
    256,
  ))
  const permissionSet = new Set(permissions)
  if (permissionSet.size !== permissions.length) {
    fail('invalid-native-client', 'native-client.json.permissions contains duplicates.')
  }
  const supported = permissions.every(permission => (
    permission === 'ui.inspector'
      || permission === 'ui.settings-link'
      || permission === 'ui.command'
      || permission === 'ui.card'
      || permission === 'ui.reference'
      || /^host\.tool:[A-Za-z0-9][A-Za-z0-9._/-]{0,127}$/.test(permission)
      || /^host\.service:[A-Za-z0-9][A-Za-z0-9._/-]{0,127}\.[A-Za-z0-9][A-Za-z0-9._/-]{0,127}$/.test(permission)
      || /^settings\.read:[A-Za-z0-9][A-Za-z0-9._/-]{0,127}$/.test(permission)
  ))
  if (!supported) {
    fail('invalid-native-client', 'native-client.json.permissions contains an unsupported capability.')
  }
  const missing = [...requiredPermissions].filter(permission => !permissionSet.has(permission))
  const unused = permissions.filter(permission => !requiredPermissions.has(permission))
  if (missing.length > 0 || unused.length > 0) {
    fail('invalid-native-client', `native-client permissions must exactly match the declared contributions (missing: ${missing.join(', ') || 'none'}; unused: ${unused.join(', ') || 'none'}).`)
  }
  return [...permissions].sort()
}

function validateNativeClientDocument(document, entries) {
  assertAllowedKeys(document, new Set([
    'schemaVersion',
    'minimumRuntime',
    'contributions',
    'endpoints',
    'permissions',
  ]), 'native-client.json')
  if (document.schemaVersion !== 1 && document.schemaVersion !== 2) {
    fail('invalid-native-client', 'native-client.json.schemaVersion must be 1 or 2.')
  }
  if (!Number.isSafeInteger(document.minimumRuntime)
    || document.minimumRuntime < 1
    || document.minimumRuntime > NATIVE_CLIENT_RUNTIME_VERSION
    || document.minimumRuntime !== document.schemaVersion) {
    fail('native-client-runtime', `native-client.json requires unsupported runtime ${JSON.stringify(document.minimumRuntime)}.`)
  }
  assertAllowedKeys(
    document.contributions,
    document.schemaVersion === 1
      ? new Set(['inspectors', 'settings', 'commands'])
      : new Set(['inspectors', 'settings', 'commands', 'cards', 'references']),
    'native-client.json.contributions',
  )

  const entryKinds = loaderEntryKinds(entries)
  const endpoints = nativeClientArray(
    document.endpoints,
    'native-client.json.endpoints',
    MAXIMUM_NATIVE_CLIENT_ENDPOINTS,
  ).map((raw, index) => validateNativeClientEndpoint(raw, index, entryKinds))
  const inspectors = nativeClientArray(
    document.contributions.inspectors,
    'native-client.json.contributions.inspectors',
    MAXIMUM_NATIVE_CLIENT_CONTRIBUTIONS,
  ).map(validateNativeClientInspector)
  const settings = nativeClientArray(
    document.contributions.settings,
    'native-client.json.contributions.settings',
    MAXIMUM_NATIVE_CLIENT_CONTRIBUTIONS,
  ).map(validateNativeClientSettingsLink)
  const commands = nativeClientArray(
    document.contributions.commands,
    'native-client.json.contributions.commands',
    MAXIMUM_NATIVE_CLIENT_CONTRIBUTIONS,
  ).map(validateNativeClientCommand)
  const cards = nativeClientArray(
    document.contributions.cards,
    'native-client.json.contributions.cards',
    MAXIMUM_NATIVE_CLIENT_CONTRIBUTIONS,
  ).map(validateNativeClientCard)
  const references = nativeClientArray(
    document.contributions.references,
    'native-client.json.contributions.references',
    MAXIMUM_NATIVE_CLIENT_CONTRIBUTIONS,
  ).map(validateNativeClientReference)
  if (inspectors.length + settings.length + commands.length + cards.length + references.length === 0) {
    fail('invalid-native-client', 'native-client.json must declare at least one contribution.')
  }
  if (inspectors.length + settings.length + commands.length + cards.length + references.length
      > MAXIMUM_NATIVE_CLIENT_CONTRIBUTIONS) {
    fail('invalid-native-client', `native-client.json must declare at most ${MAXIMUM_NATIVE_CLIENT_CONTRIBUTIONS} contributions.`)
  }

  const endpointIDs = new Set()
  for (const endpoint of endpoints) {
    if (endpointIDs.has(endpoint.id)) {
      fail('invalid-native-client', `Duplicate native endpoint id ${JSON.stringify(endpoint.id)}.`)
    }
    endpointIDs.add(endpoint.id)
  }
  const inspectorIDs = new Set()
  const referencedEndpointIDs = new Set()
  for (const inspector of inspectors) {
    if (inspectorIDs.has(inspector.id)) {
      fail('invalid-native-client', `Duplicate native inspector id ${JSON.stringify(inspector.id)}.`)
    }
    inspectorIDs.add(inspector.id)
    if (!endpointIDs.has(inspector.endpoint)) {
      fail('invalid-native-client', `Inspector ${JSON.stringify(inspector.id)} references an unknown endpoint.`)
    }
    referencedEndpointIDs.add(inspector.endpoint)
  }
  const settingsIDs = new Set()
  for (const contribution of settings) {
    if (settingsIDs.has(contribution.id)) {
      fail('invalid-native-client', `Duplicate native settings link id ${JSON.stringify(contribution.id)}.`)
    }
    settingsIDs.add(contribution.id)
  }
  const commandNames = new Set()
  for (const command of commands) {
    if (commandNames.has(command.name)) {
      fail('invalid-native-client', `Duplicate native command ${JSON.stringify(command.name)}.`)
    }
    commandNames.add(command.name)
  }
  const cardIDs = new Set()
  for (const card of cards) {
    if (cardIDs.has(card.id)) {
      fail('invalid-native-client', `Duplicate native card id ${JSON.stringify(card.id)}.`)
    }
    cardIDs.add(card.id)
  }
  const referenceIDs = new Set()
  for (const reference of references) {
    if (referenceIDs.has(reference.id)) {
      fail('invalid-native-client', `Duplicate native reference id ${JSON.stringify(reference.id)}.`)
    }
    referenceIDs.add(reference.id)
  }
  const unusedEndpoints = endpoints.filter(endpoint => !referencedEndpointIDs.has(endpoint.id))
  if (unusedEndpoints.length > 0) {
    fail('invalid-native-client', `Unused native endpoint ${JSON.stringify(unusedEndpoints[0].id)} is not exposed.`)
  }

  const requiredPermissions = new Set()
  if (inspectors.length > 0) requiredPermissions.add('ui.inspector')
  if (settings.length > 0) requiredPermissions.add('ui.settings-link')
  if (commands.length > 0) requiredPermissions.add('ui.command')
  if (cards.length > 0) requiredPermissions.add('ui.card')
  if (references.length > 0) requiredPermissions.add('ui.reference')
  for (const inspector of inspectors) {
    const endpoint = endpoints.find(candidate => candidate.id === inspector.endpoint)
    requiredPermissions.add(`host.service:${endpoint.service}.${endpoint.method}`)
  }
  for (const contribution of settings) {
    requiredPermissions.add(`settings.read:${contribution.namespace}`)
  }
  for (const command of commands) {
    requiredPermissions.add(`host.tool:${command.action.name}`)
  }

  const permissions = validateNativeClientPermissions(document.permissions, requiredPermissions)
  const normalized = {
    schemaVersion: document.schemaVersion,
    minimumRuntime: document.minimumRuntime,
    contributions: {
      inspectors: inspectors.sort((left, right) => left.order - right.order || left.id.localeCompare(right.id)),
      settings: settings.sort((left, right) => left.order - right.order || left.id.localeCompare(right.id)),
      commands: commands.sort((left, right) => left.order - right.order || left.name.localeCompare(right.name)),
      ...(document.schemaVersion === 1 ? {} : {
        cards: cards.sort((left, right) => left.order - right.order || left.id.localeCompare(right.id)),
        references: references.sort((left, right) => left.order - right.order || left.id.localeCompare(right.id)),
      }),
    },
    endpoints: endpoints.sort((left, right) => left.id.localeCompare(right.id)),
    permissions,
  }
  assertNativeClientCredentialFree(normalized, 'native-client.json')
  return normalized
}

async function validateNativeClient(packageRoot, packageManifest, entries) {
  const declaration = packageManifest.dsh?.nativeClient
  if (declaration === undefined) return undefined
  assertAllowedKeys(declaration, new Set([
    'schemaVersion',
    'platform',
    'manifest',
    'inject',
    'immediately',
  ]), 'package.json.dsh.nativeClient')
  if (declaration.schemaVersion !== 1) {
    fail('invalid-native-client', 'package.json.dsh.nativeClient.schemaVersion must be 1.')
  }
  if (declaration.platform !== 'ios-native') {
    fail('invalid-native-client', 'package.json.dsh.nativeClient.platform must be "ios-native".')
  }
  const relativeManifest = safeRelativePath(
    declaration.manifest,
    'package.json.dsh.nativeClient.manifest',
  )
  const manifestPath = path.resolve(packageRoot, ...relativeManifest.split('/'))
  if (!isContained(manifestPath, packageRoot)) {
    fail('invalid-native-client', 'The native client manifest escapes the package directory.')
  }
  const inject = nativeClientArray(
    declaration.inject,
    'package.json.dsh.nativeClient.inject',
    32,
  ).map((value, index) => {
    const name = nativeClientText(value, `package.json.dsh.nativeClient.inject[${index}]`, 128)
    if (!NATIVE_CLIENT_SERVICE_PATTERN.test(name)) {
      fail('invalid-native-client', 'package.json.dsh.nativeClient.inject contains an invalid service name.')
    }
    return name
  })
  if (new Set(inject).size !== inject.length) {
    fail('invalid-native-client', 'package.json.dsh.nativeClient.inject contains duplicates.')
  }
  const immediately = declaration.immediately ?? false
  if (typeof immediately !== 'boolean') {
    fail('invalid-native-client', 'package.json.dsh.nativeClient.immediately must be boolean.')
  }
  const document = await readJSONFile(manifestPath, MAXIMUM_NATIVE_CLIENT_MANIFEST_BYTES)
  const normalized = validateNativeClientDocument(document, entries)
  const sourceDigest = createHash('sha256')
    .update(JSON.stringify({
      declaration: {
        schemaVersion: 1,
        platform: 'ios-native',
        manifest: relativeManifest,
        inject,
        immediately,
      },
      manifest: normalized,
    }))
    .digest('hex')
  return {
    ...normalized,
    platform: 'ios-native',
    manifest: relativeManifest,
    inject,
    immediately,
    sourceDigest,
  }
}

async function validateBundleDirectory(root) {
  const manifests = []
  for (const packageJSONPath of await packageCandidates(root)) {
    const manifest = await readJSONFile(packageJSONPath)
    if (isPlainObject(manifest?.dsh?.bundle)) manifests.push({ packageJSONPath, manifest })
  }
  if (manifests.length === 0) fail('invalid-manifest', 'No package.json with a dsh.bundle manifest was found.')
  const rootManifest = manifests.find(candidate => path.dirname(candidate.packageJSONPath) === root)
  const selected = rootManifest ?? (manifests.length === 1 ? manifests[0] : undefined)
  if (selected === undefined) {
    fail('ambiguous-bundle', 'The repository contains multiple dsh.bundle packages; use a GitHub /tree/... subfolder URL.')
  }
  const { manifest } = selected
  const packageRoot = path.dirname(selected.packageJSONPath)
  const name = manifest.name
  if (typeof name !== 'string' || !npmPackageName(name)) fail('invalid-manifest', 'package.json has an invalid name.')
  validateDependencyMap(manifest, 'dependencies')
  validateDependencyMap(manifest, 'optionalDependencies')
  validateDependencyMap(manifest, 'peerDependencies')
  const patchDeclaration = manifest.dsh.bundle.patch
  const patchRelativePath = safeRelativePath(patchDeclaration, 'dsh.bundle.patch')
  const patchPath = path.resolve(packageRoot, ...patchRelativePath.split('/'))
  if (!isContained(patchPath, packageRoot)) fail('invalid-manifest', 'dsh.bundle.patch escapes the package directory.')
  const patchContent = await readFile(patchPath, 'utf8').catch(() => undefined)
  if (patchContent === undefined) fail('invalid-manifest', `Bundle patch ${patchRelativePath} is missing.`)
  if (patchContent.length > 1024 * 1024) fail('invalid-patch', 'The bundle patch is too large.')
  if (/!!js\b/.test(patchContent)) {
    fail('unsafe-patch', 'Mobile plugins cannot use !!js patch expressions.')
  }
  let patches
  try {
    patches = loadOverlayPatches('harness-mobile', patchPath)
  } catch (error) {
    fail('invalid-patch', error instanceof Error ? error.message : String(error))
  }
  const entries = validateBundlePatches(patches)
  await validateDeclaredPackageEntrypoint(packageRoot, manifest, name, entries)
  const nativeClient = await validateNativeClient(packageRoot, manifest, entries)
  return {
    packageRoot,
    id: sanitizedPluginID(name),
    name,
    version: publicText(manifest.version, 80) ?? '0.0.0',
    description: publicText(manifest.description, 600),
    license: typeof manifest.license === 'string'
      ? publicText(manifest.license, 120)
      : publicText(manifest.license?.type, 120),
    entries,
    ...(nativeClient === undefined ? {} : { nativeClient }),
  }
}

function safeChildEnvironment(extra = {}) {
  const environment = {}
  for (const [key, value] of Object.entries(process.env)) {
    // The long-lived Host needs --jitless under iSH, but inheriting it makes
    // npm's own Node process lose WebAssembly and breaks its HTTP stack.
    if (key.toUpperCase() === 'NODE_OPTIONS') continue
    const normalized = key.toLowerCase().replace(/[^a-z]/g, '')
    if (['apikey', 'authorization', 'accesstoken', 'refreshtoken', 'secretkey', 'clientsecret', 'password']
      .some(fragment => normalized.includes(fragment))) continue
    if (typeof value === 'string') environment[key] = value
  }
  return { ...environment, ...extra }
}

async function runProcess(executable, args, options = {}) {
  return await new Promise((resolve, reject) => {
    const child = spawn(executable, args, {
      cwd: options.cwd,
      env: safeChildEnvironment(options.env),
      stdio: ['ignore', 'pipe', 'pipe'],
    })
    let stdout = ''
    let stderr = ''
    let outputBytes = 0
    let completed = false
    let timedOut = false
    let outputExceeded = false
    const timeout = setTimeout(() => {
      if (completed) return
      timedOut = true
      child.kill('SIGKILL')
    }, options.timeoutMS ?? NPM_TIMEOUT_MS)
    const append = (channel, chunk) => {
      outputBytes += chunk.length
      if (outputBytes > MAXIMUM_PROCESS_OUTPUT_BYTES) {
        outputExceeded = true
        child.kill('SIGKILL')
        return
      }
      if (channel === 'stdout') stdout += chunk.toString('utf8')
      else stderr += chunk.toString('utf8')
    }
    child.stdout.on('data', chunk => append('stdout', chunk))
    child.stderr.on('data', chunk => append('stderr', chunk))
    child.once('error', (error) => {
      if (completed) return
      completed = true
      clearTimeout(timeout)
      reject(error)
    })
    child.once('exit', (code, signal) => {
      if (completed) return
      completed = true
      clearTimeout(timeout)
      if (outputExceeded) {
        reject(new MarketplaceError('process-output-limit', `${executable} emitted too much output.`))
        return
      }
      if (timedOut) {
        reject(new MarketplaceError('process-timeout', `${executable} timed out after ${options.timeoutMS ?? NPM_TIMEOUT_MS}ms.`))
        return
      }
      resolve({ code: code ?? -1, signal, stdout, stderr })
    })
  })
}

function streamHTTPSBounded(
  url,
  maximumBytes,
  timeoutMS,
  allowedHosts,
  onChunk,
) {
  return new Promise((resolve, reject) => {
    let settled = false

    const failOnce = error => {
      if (settled) return
      settled = true
      reject(error)
    }

    const finishOnce = value => {
      if (settled) return
      settled = true
      resolve(value)
    }

    const visit = (currentURL, redirectCount) => {
      let request
      try {
        request = https.get(currentURL, {
          headers: { 'user-agent': 'HarnessMobile-iSH-PluginMarket/1.0' },
        }, response => {
          const status = response.statusCode ?? 0
          const location = response.headers.location
          if (status >= 300 && status < 400 && location !== undefined) {
            response.resume()
            if (redirectCount >= 5) {
              failOnce(new MarketplaceError(
                'download-failed',
                'The download followed too many redirects.',
              ))
              return
            }
            let nextURL
            try {
              nextURL = new URL(location, currentURL)
            } catch {
              failOnce(new MarketplaceError(
                'download-failed',
                'The download returned an invalid redirect.',
              ))
              return
            }
            if (nextURL.protocol !== 'https:'
              || !allowedHosts.has(nextURL.hostname.toLowerCase())) {
              failOnce(new MarketplaceError(
                'download-failed',
                'The download redirected outside the approved hosts.',
              ))
              return
            }
            visit(nextURL, redirectCount + 1)
            return
          }

          if (status < 200 || status >= 300) {
            response.resume()
            failOnce(new MarketplaceError(
              'download-failed',
              `Download failed with HTTP ${status}.`,
            ))
            return
          }

          let size = 0
          let writeChain = Promise.resolve()
          response.on('data', chunk => {
            if (settled) return
            const buffer = Buffer.from(chunk)
            size += buffer.byteLength
            if (size > maximumBytes) {
              response.destroy()
              failOnce(new MarketplaceError(
                'download-limit',
                `Download exceeds the ${maximumBytes}-byte on-device limit.`,
              ))
              return
            }
            response.pause()
            writeChain = writeChain
              .then(() => onChunk(buffer))
              .then(() => response.resume())
              .catch(error => {
                response.destroy()
                failOnce(error)
              })
          })
          response.once('error', failOnce)
          response.once('end', () => finishOnce(size))
        })
      } catch (error) {
        failOnce(error)
        return
      }
      request.setTimeout(timeoutMS, () => {
        request.destroy()
        failOnce(new MarketplaceError(
          'download-timeout',
          `Download timed out after ${timeoutMS}ms.`,
        ))
      })
      request.once('error', failOnce)
    }

    let initialURL
    try {
      initialURL = new URL(url)
    } catch (error) {
      failOnce(error)
      return
    }
    if (initialURL.protocol !== 'https:'
      || !allowedHosts.has(initialURL.hostname.toLowerCase())) {
      failOnce(new MarketplaceError(
        'download-failed',
        'The download URL is outside the approved hosts.',
      ))
      return
    }
    visit(initialURL, 0)
  })
}

async function fetchBoundedViaHTTPS(url, maximumBytes, timeoutMS, allowedHosts, asText) {
  const chunks = []
  const size = await streamHTTPSBounded(
    url,
    maximumBytes,
    timeoutMS,
    allowedHosts,
    chunk => {
      chunks.push(chunk)
    },
  )
  const data = Buffer.concat(chunks, size)
  return asText ? data.toString('utf8') : data
}

function canUseUndiciFetch() {
  // iSH exposes a reduced Node runtime. Undici references WebAssembly during
  // initialization and may terminate the Host before its rejected promise can
  // reach our normal transport fallback.
  return typeof globalThis.fetch === 'function'
    && typeof globalThis.WebAssembly !== 'undefined'
}

async function fetchBounded(url, maximumBytes, timeoutMS, asText = false) {
  if (!canUseUndiciFetch()) {
    return await fetchBoundedViaHTTPS(
      url,
      maximumBytes,
      timeoutMS,
      ALLOWED_MARKET_HOSTS,
      asText,
    )
  }
  const controller = new AbortController()
  const timeout = setTimeout(() => controller.abort(), timeoutMS)
  try {
    const response = await fetch(url, {
      redirect: 'follow',
      signal: controller.signal,
      headers: { 'user-agent': 'HarnessMobile-iSH-PluginMarket/1.0' },
    })
    if (!response.ok || response.body === null) {
      fail('download-failed', `Download failed with HTTP ${response.status}.`)
    }
    const finalURL = new URL(response.url)
    if (finalURL.protocol !== 'https:' || !ALLOWED_MARKET_HOSTS.has(finalURL.hostname.toLowerCase())) {
      fail('download-failed', 'The plugin catalog redirected outside the approved mirror hosts.')
    }
    const reader = response.body.getReader()
    const chunks = []
    let size = 0
    for (;;) {
      const { done, value } = await reader.read()
      if (done) break
      size += value.byteLength
      if (size > maximumBytes) {
        await reader.cancel()
        fail('download-limit', `Download exceeds the ${maximumBytes}-byte on-device limit.`)
      }
      chunks.push(value)
    }
    const data = Buffer.concat(chunks.map(chunk => Buffer.from(chunk)), size)
    return asText ? data.toString('utf8') : data
  } catch (fetchError) {
    // iSH's guest networking can work for wget while Node's Undici fetch
    // fails during address selection or TLS setup. Keep the same on-device
    // policy and use Node's native https client as a narrow transport fallback.
    clearTimeout(timeout)
    try {
      return await fetchBoundedViaHTTPS(
        url,
        maximumBytes,
        timeoutMS,
        ALLOWED_MARKET_HOSTS,
        asText,
      )
    } catch (httpsError) {
      throw downloadTransportError('Plugin catalog download', [
        { transport: 'undici-fetch', error: fetchError },
        { transport: 'node-https', error: httpsError },
      ])
    }
  } finally {
    clearTimeout(timeout)
  }
}

async function downloadFileViaHTTPS(url, destination) {
  let file
  try {
    file = await open(destination, 'wx', 0o600)
    await streamHTTPSBounded(
      url,
      MAXIMUM_ZIP_BYTES,
      DOWNLOAD_TIMEOUT_MS,
      ALLOWED_DOWNLOAD_HOSTS,
      chunk => file.write(chunk),
    )
  } catch (error) {
    await rm(destination, { force: true }).catch(() => {})
    throw error
  } finally {
    await file?.close().catch(() => {})
  }
}

async function downloadFileViaFetch(url, destination) {
  const controller = new AbortController()
  const timeout = setTimeout(() => controller.abort(), DOWNLOAD_TIMEOUT_MS)
  let file
  try {
    const response = await fetch(url, {
      redirect: 'follow',
      signal: controller.signal,
      headers: { 'user-agent': 'HarnessMobile-iSH-PluginMarket/1.0' },
    })
    if (!response.ok || response.body === null) {
      fail('download-failed', `Download failed with HTTP ${response.status}.`)
    }
    const finalURL = new URL(response.url)
    if (finalURL.protocol !== 'https:' || !ALLOWED_DOWNLOAD_HOSTS.has(finalURL.hostname.toLowerCase())) {
      fail('download-failed', 'The download redirected outside the approved GitHub hosts.')
    }
    file = await open(destination, 'wx', 0o600)
    const reader = response.body.getReader()
    let size = 0
    for (;;) {
      const { done, value } = await reader.read()
      if (done) break
      size += value.byteLength
      if (size > MAXIMUM_ZIP_BYTES) {
        await reader.cancel()
        fail('download-limit', `Download exceeds the ${MAXIMUM_ZIP_BYTES}-byte on-device limit.`)
      }
      await file.write(value)
    }
  } finally {
    clearTimeout(timeout)
    await file?.close().catch(() => {})
  }
}

async function downloadFileViaWget(url, destination) {
  let parsed
  try {
    parsed = new URL(url)
  } catch (error) {
    throw error
  }
  // This fallback only receives a direct codeload archive URL generated above.
  // A fixed host avoids relying on wget's redirect policy inside the guest.
  if (parsed.protocol !== 'https:' || parsed.hostname.toLowerCase() !== 'codeload.github.com') {
    fail('download-failed', 'wget is restricted to direct codeload.github.com archives.')
  }
  const result = await runProcess('wget', [
    '-q',
    '-T', '20',
    '-t', '1',
    '-O', destination,
    parsed.toString(),
  ], { timeoutMS: DOWNLOAD_TIMEOUT_MS })
  if (result.code !== 0) {
    throw new MarketplaceError(
      'download-wget-failed',
      result.stderr.trim() || result.stdout.trim() || `wget exited with ${result.code}.`,
    )
  }
  const info = await stat(destination)
  if (!info.isFile() || info.size <= 0) {
    fail('download-wget-failed', 'wget did not produce a plugin archive.')
  }
  if (info.size > MAXIMUM_ZIP_BYTES) {
    fail('download-limit', `Download exceeds the ${MAXIMUM_ZIP_BYTES}-byte on-device limit.`)
  }
}

async function downloadFile(url, destination) {
  const failures = []
  const transports = [
    ['node-https', () => downloadFileViaHTTPS(url, destination)],
    ['wget', () => downloadFileViaWget(url, destination)],
  ]
  if (canUseUndiciFetch()) {
    transports.unshift(['undici-fetch', () => downloadFileViaFetch(url, destination)])
  }
  for (const [transport, operation] of transports) {
    try {
      await operation()
      return
    } catch (error) {
      failures.push({ transport, error })
      await rm(destination, { force: true }).catch(() => {})
    }
  }
  throw downloadTransportError('Plugin archive download', failures)
}

function isNotFoundDownloadError(error) {
  if (!(error instanceof MarketplaceError)) return false
  const messages = [
    error.message,
    ...(Array.isArray(error.data?.transports)
      ? error.data.transports.map(transport => transport?.message)
      : []),
  ]
  return messages.some(message => typeof message === 'string' && /HTTP 404\b/i.test(message))
}

async function atomicWriteJSON(destination, value) {
  const temporary = `${destination}.${process.pid}.${randomUUID()}.tmp`
  try {
    await writeFile(temporary, `${JSON.stringify(value, undefined, 2)}\n`, { flag: 'wx', mode: 0o600 })
    await rename(temporary, destination)
  } finally {
    await rm(temporary, { force: true }).catch(() => {})
  }
}

async function directoryExists(directory) {
  try {
    return (await stat(directory)).isDirectory()
  } catch {
    return false
  }
}

function packageDirectoryFromAnchor(anchor, packageName) {
  for (const searchPath of createRequire(anchor).resolve.paths(packageName) ?? []) {
    const candidate = path.join(searchPath, packageName)
    if (existsSync(path.join(candidate, 'package.json'))) return candidate
  }
  return undefined
}

async function scanForNativeAddons(root) {
  let visited = 0
  const visit = async (directory) => {
    const stream = await opendir(directory)
    for await (const entry of stream) {
      visited += 1
      if (visited > 100_000) fail('dependency-limit', 'Installed dependency tree is too large for the phone runtime.')
      const target = path.join(directory, entry.name)
      const info = await lstat(target)
      if (info.isSymbolicLink()) continue
      if (info.isDirectory()) {
        await visit(target)
        continue
      }
      const lower = target.toLowerCase()
      if (lower.endsWith('.node') || path.basename(lower) === 'binding.gyp'
        || lower.split(path.sep).includes('prebuilds')) {
        fail('native-addon', `Native addon ${path.relative(root, target)} is not supported by the iSH JavaScript runtime.`)
      }
    }
  }
  if (await directoryExists(root)) await visit(root)
}

function sourcePublicValue(source) {
  return {
    kind: source.kind,
    location: source.location,
    ...(source.repositoryURL === undefined ? {} : { repositoryURL: source.repositoryURL }),
    ...(source.repositoryKey === undefined ? {} : { repositoryKey: source.repositoryKey }),
    ...(source.ref === undefined ? {} : { ref: source.ref }),
    ...(source.subpath === undefined ? {} : { subpath: source.subpath }),
  }
}

function publicPlugin(record, loaded) {
  const nativeClient = record.nativeClient
  return {
    id: record.id,
    name: record.name,
    version: record.version,
    ...(record.description === undefined ? {} : { description: record.description }),
    ...(record.license === undefined ? {} : { license: record.license }),
    source: sourcePublicValue(record.source),
    enabled: record.enabled,
    state: loaded ? 'enabled' : (record.lastError === undefined ? 'disabled' : 'failed'),
    installedAt: record.installedAt,
    updatedAt: record.updatedAt,
    entryCount: record.entries.length,
    hasNativeClient: nativeClient !== undefined,
    ...(nativeClient === undefined ? {} : {
      nativeContributionCount: nativeClient.contributions.inspectors.length
        + nativeClient.contributions.settings.length
        + nativeClient.contributions.commands.length,
    }),
    ...(record.lastError === undefined ? {} : { lastError: publicText(record.lastError, 1000) }),
  }
}

function isRootObjectPrototype(value) {
  return value !== null
    && Object.getPrototypeOf(value) === null
    && Object.getOwnPropertyDescriptor(value, 'constructor')?.value?.name === 'Object'
}

function isRootFunctionPrototype(value) {
  return typeof value === 'function'
    && Object.getPrototypeOf(value) === null
    && Object.getOwnPropertyDescriptor(value, 'constructor')?.value?.name === 'Function'
}

function isIntrinsicServicePrototype(value) {
  return value === Object.prototype
    || value === Function.prototype
    || isRootObjectPrototype(value)
    || isRootFunctionPrototype(value)
}

function nativeClientServiceMethod(value, method) {
  if (method === 'call' && typeof value === 'function') return value
  if (value === null || (typeof value !== 'object' && typeof value !== 'function')) return undefined
  let cursor = value
  while (cursor !== null && !isIntrinsicServicePrototype(cursor)) {
    const descriptor = Object.getOwnPropertyDescriptor(cursor, method)
    if (descriptor !== undefined) return typeof descriptor.value === 'function' ? descriptor.value : undefined
    cursor = Object.getPrototypeOf(cursor)
  }
  return undefined
}

function entryBelongsToGroup(entry, groupEntry) {
  let cursor = entry
  const seen = new Set()
  while (cursor !== undefined && cursor !== null && !seen.has(cursor)) {
    if (cursor === groupEntry) return true
    seen.add(cursor)
    cursor = cursor.parent?.ctx?.fiber?.entry
  }
  return false
}

export class MarketplaceManager {
  constructor(ctx, options) {
    this.ctx = ctx
    this.workspaceRoot = path.resolve(options.workspaceRoot)
    this.hostDirectory = path.resolve(options.hostDirectory)
    this.root = path.join(this.workspaceRoot, '.harness-mobile', 'plugin-market')
    this.registryPath = path.join(this.root, 'registry.json')
    this.marketCachePath = path.join(this.root, 'market-cache.json')
    this.downloadsDirectory = path.join(this.root, 'downloads')
    this.stagingDirectory = path.join(this.root, 'staging')
    this.pluginsDirectory = path.join(this.root, 'plugins')
    this.packagesDirectory = path.join(this.root, 'packages')
    this.runtimeDirectory = path.join(this.root, 'runtime')
    this.runtimeManifestPath = path.join(this.runtimeDirectory, 'package.json')
    this.npmCacheDirectory = path.join(this.root, 'npm-cache')
    this.importsDirectory = path.join(this.workspaceRoot, '.harness-mobile', 'plugin-imports')
    this.npmExecutable = options.npmExecutable ?? 'npm'
    this.onRevision = options.onRevision ?? (() => {})
    this.records = []
    this.loadedGroups = new Map()
    this.preparedNativeSources = new Map()
    this.nextActivationGeneration = 1
    this.mutationTail = Promise.resolve()
  }

  async start() {
    const startedAt = performance.now()
    await this.ensureLayout()
    const layoutReadyAt = performance.now()
    this.records = await this.loadRegistry()
    const registryReadyAt = performance.now()
    await this.removeOrphanStorage()
    await this.writeRuntimeManifest(this.records)
    await this.healHostPackages()
    const runtimeReadyAt = performance.now()
    let changed = false
    // Loader activation is independent per marketplace package. Restoring
    // them serially made one slow or broken plugin delay every other plugin
    // and made cold-start time grow linearly with the registry size. Validate
    // and activate with a small bounded fan-out while keeping each record's
    // rollback state isolated.
    const enabledRecords = this.records
      .map((record, index) => ({ record, index }))
      .filter(candidate => candidate.record.enabled)
    const concurrency = Math.min(4, Math.max(1, enabledRecords.length))
    let cursor = 0
    const worker = async () => {
      for (;;) {
        const candidate = enabledRecords[cursor]
        cursor += 1
        if (candidate === undefined) return
        const pluginStartedAt = performance.now()
        try {
          await this.validateRuntimeEntryPackages(candidate.record.entries)
          await this.load(candidate.record)
          if (candidate.record.lastError !== undefined) {
            this.records[candidate.index] = { ...candidate.record, lastError: undefined }
            changed = true
          }
          console.error(`[plugin-host] restored ${candidate.record.id} in ${Math.round(performance.now() - pluginStartedAt)}ms`)
        } catch (error) {
          this.records[candidate.index] = {
            ...candidate.record,
            enabled: false,
            lastError: error instanceof Error ? error.message : String(error),
          }
          changed = true
          console.error(`[plugin-host] failed ${candidate.record.id} in ${Math.round(performance.now() - pluginStartedAt)}ms: ${error instanceof Error ? error.message : String(error)}`)
        }
      }
    }
    await Promise.all(Array.from({ length: concurrency }, worker))
    if (changed) await this.saveRegistry(this.records)
    console.error(`[plugin-host] marketplace phases layout=${Math.round(layoutReadyAt - startedAt)}ms registry=${Math.round(registryReadyAt - layoutReadyAt)}ms runtime=${Math.round(runtimeReadyAt - registryReadyAt)}ms restore=${Math.round(performance.now() - runtimeReadyAt)}ms plugins=${enabledRecords.length}`)
  }

  async ensureLayout() {
    for (const directory of [
      this.root,
      this.downloadsDirectory,
      this.stagingDirectory,
      this.pluginsDirectory,
      this.packagesDirectory,
      this.runtimeDirectory,
      this.npmCacheDirectory,
    ]) {
      await mkdir(directory, { recursive: true, mode: 0o700 })
    }
  }

  async loadRegistry() {
    try {
      const registry = await readJSONFile(this.registryPath, 8 * 1024 * 1024)
      if (registry.schemaVersion !== 1 || !Array.isArray(registry.plugins)) {
        fail('invalid-registry', 'plugin-market/registry.json has an unsupported schema.')
      }
      registry.plugins.forEach(record => {
        if (!isPlainObject(record) || typeof record.id !== 'string' || typeof record.name !== 'string'
          || !Array.isArray(record.entries) || !isPlainObject(record.source)) {
          fail('invalid-registry', 'plugin-market/registry.json contains an invalid plugin record.')
        }
        assertJSONValue(record)
      })
      return registry.plugins
    } catch (error) {
      if (error?.code === 'ENOENT') {
        await this.saveRegistry([])
        return []
      }
      throw error
    }
  }

  async saveRegistry(records) {
    await atomicWriteJSON(this.registryPath, { schemaVersion: 1, plugins: records })
  }

  async removeOrphanStorage() {
    const managed = [
      {
        directory: this.pluginsDirectory,
        retained: new Set(this.records.map(record => path.basename(record.directory))),
      },
      {
        directory: this.packagesDirectory,
        retained: new Set(this.records.map(record => path.basename(record.tarball))),
      },
    ]
    for (const collection of managed) {
      const stream = await opendir(collection.directory)
      for await (const entry of stream) {
        if (collection.retained.has(entry.name)) continue
        await rm(path.join(collection.directory, entry.name), {
          recursive: true,
          force: true,
        })
      }
    }
  }

  serialize(operation) {
    const run = this.mutationTail.then(operation, operation)
    this.mutationTail = run.catch(() => {})
    return run
  }

  list() {
    return {
      revision: Date.now(),
      plugins: [...this.records]
        .sort((left, right) => left.name.localeCompare(right.name))
        .map(record => publicPlugin(record, this.loadedGroups.has(record.id))),
    }
  }

  async releasePreparedSource(prepared) {
    if (prepared === undefined) return
    if (prepared.temporaryArchive) {
      await rm(prepared.archivePath, { force: true }).catch(() => {})
    }
    if (prepared.cleanupSource) {
      await rm(prepared.cleanupSource, { force: true }).catch(() => {})
    }
  }

  async purgePreparedNativeSources() {
    const now = Date.now()
    const entries = [...this.preparedNativeSources.entries()]
      .sort((left, right) => left[1].createdAt - right[1].createdAt)
    for (const [token, prepared] of entries) {
      const expired = now - prepared.createdAt >= PREPARED_NATIVE_SOURCE_TTL_MS
      const overLimit = this.preparedNativeSources.size > MAXIMUM_PREPARED_NATIVE_SOURCES
      if (!expired && !overLimit) continue
      this.preparedNativeSources.delete(token)
      await this.releasePreparedSource(prepared)
    }
  }

  takePreparedNativeSource(token) {
    if (typeof token !== 'string' || !/^[a-f0-9]{32}$/.test(token)) {
      fail('invalid-prepared-source', 'The prepared native source token is invalid.')
    }
    const prepared = this.preparedNativeSources.get(token)
    if (prepared === undefined) {
      fail('prepared-source-expired', 'The prepared native source is unavailable or expired.')
    }
    this.preparedNativeSources.delete(token)
    return prepared
  }

  nativeClientDirectory() {
    const plugins = []
    for (const record of this.records) {
      const activation = this.loadedGroups.get(record.id)
      if (!record.enabled || activation === undefined || record.nativeClient === undefined) continue
      plugins.push({
        pluginId: record.id,
        packageName: record.name,
        version: record.version,
        scope: 'process',
        activationGeneration: activation.activationGeneration,
        sourceDigest: record.nativeClient.sourceDigest,
        schemaVersion: record.nativeClient.schemaVersion,
        minimumRuntime: record.nativeClient.minimumRuntime,
        inject: [...record.nativeClient.inject],
        immediately: record.nativeClient.immediately,
        contributions: structuredClone(record.nativeClient.contributions),
        endpoints: structuredClone(record.nativeClient.endpoints),
        permissions: [...record.nativeClient.permissions],
      })
    }
    plugins.sort((left, right) => left.pluginId.localeCompare(right.pluginId))
    return { scope: 'process', plugins }
  }

  async invokeNativeClientEndpoint(params) {
    const pluginId = params?.pluginId
    const endpointId = params?.endpointId
    const activationGeneration = params?.activationGeneration
    const args = params?.arguments ?? {}
    if (typeof pluginId !== 'string' || !NATIVE_CLIENT_ID_PATTERN.test(pluginId)
      || typeof endpointId !== 'string' || !NATIVE_CLIENT_ID_PATTERN.test(endpointId)
      || !Number.isSafeInteger(activationGeneration) || activationGeneration < 1) {
      fail('invalid-request', 'Native endpoint invocation has an invalid identity.')
    }
    if (!isPlainObject(args)) {
      fail('invalid-request', 'Native endpoint arguments must be a JSON object.')
    }
    assertNativeClientCredentialFree(args, 'native endpoint arguments')
    if (Buffer.byteLength(JSON.stringify(args), 'utf8') > MAXIMUM_NATIVE_CLIENT_ARGUMENT_BYTES) {
      fail('invalid-request', 'Native endpoint arguments are too large.')
    }

    const record = this.records.find(candidate => candidate.id === pluginId)
    const activation = this.loadedGroups.get(pluginId)
    if (record?.nativeClient === undefined || activation === undefined || !record.enabled) {
      fail('plugin-not-running', `Native client plugin ${JSON.stringify(pluginId)} is not active.`)
    }
    if (activation.activationGeneration !== activationGeneration) {
      fail('stale-generation', `Native client activation ${activationGeneration} is no longer active.`)
    }
    const endpoint = record.nativeClient.endpoints.find(candidate => candidate.id === endpointId)
    if (endpoint === undefined || endpoint.readOnly !== true || endpoint.kind !== 'hostService') {
      fail('endpoint-not-found', `Native client endpoint ${JSON.stringify(endpointId)} is not declared.`)
    }

    let groupEntry
    let targetEntry
    try {
      groupEntry = this.ctx.loader.resolve(activation.groupID)
      targetEntry = this.ctx.loader.resolve(endpoint.entry)
    } catch {
      fail('endpoint-not-active', 'The declared native endpoint Loader entry is not active.')
    }
    if (!entryBelongsToGroup(targetEntry, groupEntry)) {
      fail('endpoint-scope', 'The declared native endpoint does not belong to this plugin activation.')
    }

    const candidates = []
    for (const runtime of this.ctx.registry.values()) {
      for (const fiber of runtime.fibers) {
        if (fiber.uid === null || fiber.state !== 2 || fiber.entry !== targetEntry) continue
        const implementation = fiber.store?.[endpoint.service]
        if (implementation === undefined || implementation.fiber !== fiber) continue
        const method = nativeClientServiceMethod(implementation.value, endpoint.method)
        if (method !== undefined) {
          candidates.push({ value: implementation.value, method })
        }
      }
    }
    if (candidates.length === 0) {
      fail('endpoint-not-active', `Host service ${JSON.stringify(endpoint.service)}.${endpoint.method} is unavailable.`)
    }
    if (candidates.length > 1) {
      fail('endpoint-ambiguous', `Host service ${JSON.stringify(endpoint.service)}.${endpoint.method} is ambiguous.`)
    }

    const candidate = candidates[0]
    let timeoutHandle
    const timeout = new Promise((_, reject) => {
      timeoutHandle = setTimeout(() => {
        reject(new MarketplaceError('endpoint-timeout', 'The native inspector endpoint timed out.'))
      }, 5_000)
      timeoutHandle.unref?.()
    })
    let value
    try {
      value = await Promise.race([
        Promise.resolve(candidate.method.call(candidate.value, structuredClone(args))),
        timeout,
      ])
    } finally {
      clearTimeout(timeoutHandle)
    }
    assertJSONValue(value, 'native endpoint result')
    assertNativeClientCredentialFree(value, 'native endpoint result')
    if (Buffer.byteLength(JSON.stringify(value), 'utf8') > MAXIMUM_NATIVE_CLIENT_ENDPOINT_RESULT_BYTES) {
      fail('endpoint-result-too-large', 'Native endpoint result exceeds the 64 KiB wire limit.')
    }
    return { ok: true, value }
  }

  async catalog({ forceRefresh = false } = {}) {
    let cache
    try {
      cache = await readJSONFile(this.marketCachePath, 8 * 1024 * 1024)
    } catch (error) {
      if (error?.code !== 'ENOENT') cache = undefined
    }
    const fetchedAtMS = cache?.fetchedAt === undefined ? 0 : Date.parse(cache.fetchedAt)
    const fresh = Number.isFinite(fetchedAtMS) && Date.now() - fetchedAtMS < MARKET_CACHE_TTL_MS
    if (cache === undefined || forceRefresh || !fresh) {
      try {
        let markdown
        let sourceURL
        let lastError
        for (const candidate of MARKET_README_URLS) {
          try {
            markdown = await fetchBounded(candidate, MAXIMUM_MARKET_BYTES, 20_000, true)
            sourceURL = candidate
            break
          } catch (error) {
            lastError = error
          }
        }
        if (markdown === undefined) throw lastError ?? new Error('Market fetch failed.')
        cache = {
          schemaVersion: 1,
          sourceURL,
          fetchedAt: new Date().toISOString(),
          items: parseMarketReadme(markdown),
        }
        await atomicWriteJSON(this.marketCachePath, cache)
      } catch (error) {
        if (cache === undefined) throw error
      }
    }
    const installed = new Map(
      this.records
        .filter(record => record.source.repositoryKey !== undefined)
        .map(record => [record.source.repositoryKey, record]),
    )
    return {
      sourceURL: cache.sourceURL,
      fetchedAt: cache.fetchedAt,
      stale: Date.now() - Date.parse(cache.fetchedAt) >= MARKET_CACHE_TTL_MS,
      items: cache.items.map(item => {
        const record = installed.get(item.repositoryKey)
        return {
          ...item,
          installed: record !== undefined,
          ...(record === undefined ? {} : {
            installedPluginID: record.id,
            installedVersion: record.version,
          }),
        }
      }),
    }
  }

  async install(params) {
    return await this.serialize(async () => {
      if (!isPlainObject(params?.source)) fail('invalid-source', 'plugin/install requires a source object.')
      const replaceExisting = params.replace === true
      await this.purgePreparedNativeSources()
      const prepared = params.preparedToken === undefined
        ? await this.prepareSource(params.source)
        : this.takePreparedNativeSource(params.preparedToken)
      const token = randomUUID().replaceAll('-', '').slice(0, 16)
      const archivePath = prepared.archivePath
      const stagingPath = path.join(this.stagingDirectory, `install-${token}`)
      let storedPluginDirectory
      let storedTarball
      try {
        const archiveInfo = await stat(archivePath)
        if (!archiveInfo.isFile() || archiveInfo.size > MAXIMUM_ZIP_BYTES) {
          fail('zip-limit', 'The plugin ZIP exceeds the on-device size limit.')
        }
        const archiveEntries = await inspectArchive(archivePath)
        const extractionPlan = archiveExtractionPlan(archiveEntries, prepared.subpath)
        await extractArchive(archivePath, stagingPath, extractionPlan)
        let validated
        try {
          validated = await validateBundleDirectory(stagingPath)
        } catch (error) {
          await attachNativeCompilationCandidate(error, stagingPath, prepared.publicSource)
          throw error
        }
        const existingIndex = this.records.findIndex(record => record.id === validated.id || record.name === validated.name)
        const existing = existingIndex < 0 ? undefined : this.records[existingIndex]
        if (existing !== undefined && !replaceExisting) {
          fail('already-installed', `Plugin ${JSON.stringify(existing.name)} is already installed.`)
        }

        storedPluginDirectory = path.join(this.pluginsDirectory, `${validated.id}-${token}`)
        const packTemporaryDirectory = path.join(this.packagesDirectory, `.pack-${token}`)
        await mkdir(packTemporaryDirectory, { recursive: true, mode: 0o700 })
        const packed = await runProcess(this.npmExecutable, [
          'pack',
          validated.packageRoot,
          '--ignore-scripts',
          '--json',
          '--pack-destination',
          packTemporaryDirectory,
        ], {
          cwd: this.runtimeDirectory,
          env: this.npmEnvironment(),
        })
        if (packed.code !== 0) {
          fail('npm-pack-failed', packed.stderr.trim() || packed.stdout.trim() || 'npm pack failed.')
        }
        let packResult
        try {
          const jsonStart = packed.stdout.indexOf('[')
          packResult = JSON.parse(packed.stdout.slice(jsonStart))[0]
        } catch {
          fail('npm-pack-failed', 'npm pack returned an invalid result.')
        }
        const packedPath = path.join(packTemporaryDirectory, packResult.filename)
        const packedInfo = await stat(packedPath)
        if (!packedInfo.isFile() || packedInfo.size > MAXIMUM_ZIP_BYTES) {
          fail('package-limit', 'The packed plugin exceeds the on-device size limit.')
        }
        storedTarball = path.join(this.packagesDirectory, `${validated.id}-${token}.tgz`)
        await rename(packedPath, storedTarball)
        await rm(packTemporaryDirectory, { recursive: true, force: true })
        await rename(validated.packageRoot, storedPluginDirectory)

        const now = new Date().toISOString()
        const nextRecord = {
          id: validated.id,
          name: validated.name,
          version: validated.version,
          ...(validated.description === undefined ? {} : { description: validated.description }),
          ...(validated.license === undefined ? {} : { license: validated.license }),
          source: prepared.publicSource,
          enabled: existing?.enabled ?? false,
          installedAt: existing?.installedAt ?? now,
          updatedAt: now,
          directory: path.relative(this.root, storedPluginDirectory).split(path.sep).join('/'),
          tarball: path.relative(this.root, storedTarball).split(path.sep).join('/'),
          entries: validated.entries,
          ...(validated.nativeClient === undefined ? {} : { nativeClient: validated.nativeClient }),
        }
        const previousRecords = this.records
        const nextRecords = [...previousRecords]
        if (existingIndex < 0) nextRecords.push(nextRecord)
        else nextRecords[existingIndex] = nextRecord
        if (existing?.enabled) await this.unload(existing.id)

        try {
          await this.reconcileRuntime(nextRecords)
          if (nextRecord.enabled) await this.load(nextRecord)
          await this.saveRegistry(nextRecords)
          this.records = nextRecords
        } catch (error) {
          await attachNativeCompilationCandidate(
            error,
            storedPluginDirectory ?? stagingPath,
            prepared.publicSource,
          )
          await this.unload(nextRecord.id).catch(() => {})
          const rollbackErrors = []
          try { await this.reconcileRuntime(previousRecords) } catch (rollback) { rollbackErrors.push(rollback) }
          // Even if npm rollback itself fails, leave the declarative runtime
          // manifest at the last committed registry state for the next Host
          // launch instead of preserving a half-installed dependency.
          try { await this.writeRuntimeManifest(previousRecords) } catch (rollback) { rollbackErrors.push(rollback) }
          if (existing?.enabled) {
            try { await this.load(existing) } catch (rollback) { rollbackErrors.push(rollback) }
          }
          if (rollbackErrors.length > 0) {
            throw new AggregateError([error, ...rollbackErrors], 'Plugin installation rollback failed.')
          }
          throw error
        }

        if (existing !== undefined) await this.removeRecordStorage(existing)
        this.onRevision()
        return { plugin: publicPlugin(nextRecord, this.loadedGroups.has(nextRecord.id)) }
      } finally {
        await rm(stagingPath, { recursive: true, force: true }).catch(() => {})
        if (prepared.temporaryArchive) await rm(archivePath, { force: true }).catch(() => {})
        if (prepared.cleanupSource) await rm(prepared.cleanupSource, { force: true }).catch(() => {})
        if (this.records.every(record => record.directory !== path.relative(this.root, storedPluginDirectory ?? ''))) {
          if (storedPluginDirectory !== undefined) await rm(storedPluginDirectory, { recursive: true, force: true }).catch(() => {})
          if (storedTarball !== undefined) await rm(storedTarball, { force: true }).catch(() => {})
        }
      }
    })
  }

  async setEnabled(id, enabled) {
    return await this.serialize(async () => {
      if (typeof id !== 'string' || typeof enabled !== 'boolean') fail('invalid-request', 'plugin/set-enabled requires id and enabled.')
      const index = this.records.findIndex(record => record.id === id)
      if (index < 0) fail('not-found', `Plugin ${JSON.stringify(id)} is not installed.`)
      const previous = this.records[index]
      if (previous.enabled === enabled && previous.lastError === undefined) {
        return { plugin: publicPlugin(previous, this.loadedGroups.has(id)) }
      }
      if (enabled) {
        try {
          await this.validateRuntimeEntryPackages(previous.entries)
          await this.load(previous)
          const next = { ...previous, enabled: true, lastError: undefined, updatedAt: new Date().toISOString() }
          const records = [...this.records]
          records[index] = next
          await this.saveRegistry(records)
          this.records = records
          this.onRevision()
          return { plugin: publicPlugin(next, true) }
        } catch (error) {
          await this.unload(id).catch(() => {})
          const failed = {
            ...previous,
            enabled: false,
            lastError: error instanceof Error ? error.message : String(error),
            updatedAt: new Date().toISOString(),
          }
          const records = [...this.records]
          records[index] = failed
          await this.saveRegistry(records).catch(() => {})
          this.records = records
          throw error
        }
      }

      await this.unload(id)
      const next = { ...previous, enabled: false, lastError: undefined, updatedAt: new Date().toISOString() }
      const records = [...this.records]
      records[index] = next
      try {
        await this.saveRegistry(records)
      } catch (error) {
        if (previous.enabled) await this.load(previous).catch(() => {})
        throw error
      }
      this.records = records
      this.onRevision()
      return { plugin: publicPlugin(next, false) }
    })
  }

  async uninstall(id) {
    return await this.serialize(async () => {
      if (typeof id !== 'string') fail('invalid-request', 'plugin/uninstall requires id.')
      const index = this.records.findIndex(record => record.id === id)
      if (index < 0) fail('not-found', `Plugin ${JSON.stringify(id)} is not installed.`)
      const previous = this.records[index]
      const previousRecords = this.records
      const nextRecords = previousRecords.filter(record => record.id !== id)
      await this.unload(id)
      try {
        await this.reconcileRuntime(nextRecords)
        await this.saveRegistry(nextRecords)
        this.records = nextRecords
      } catch (error) {
        const rollbackErrors = []
        try { await this.reconcileRuntime(previousRecords) } catch (rollback) { rollbackErrors.push(rollback) }
        if (previous.enabled) {
          try { await this.load(previous) } catch (rollback) { rollbackErrors.push(rollback) }
        }
        if (rollbackErrors.length > 0) {
          throw new AggregateError([error, ...rollbackErrors], 'Plugin uninstall rollback failed.')
        }
        throw error
      }
      await this.removeRecordStorage(previous)
      this.onRevision()
      return { ok: true, id }
    })
  }

  async clearCache({ includeNpm = false } = {}) {
    return await this.serialize(async () => {
      let removedFiles = 0
      for (const prepared of this.preparedNativeSources.values()) {
        await this.releasePreparedSource(prepared)
      }
      this.preparedNativeSources.clear()
      for (const target of [this.marketCachePath, this.downloadsDirectory, this.stagingDirectory]) {
        if (existsSync(target)) removedFiles += 1
        await rm(target, { recursive: true, force: true })
      }
      await mkdir(this.downloadsDirectory, { recursive: true, mode: 0o700 })
      await mkdir(this.stagingDirectory, { recursive: true, mode: 0o700 })
      if (includeNpm) {
        if (existsSync(this.npmCacheDirectory)) removedFiles += 1
        await rm(this.npmCacheDirectory, { recursive: true, force: true })
        await mkdir(this.npmCacheDirectory, { recursive: true, mode: 0o700 })
      }
      return { ok: true, removedFiles }
    })
  }

  async prepareNative(params) {
    return await this.serialize(async () => {
      if (!isPlainObject(params?.source)) {
        fail('invalid-source', 'plugin/prepare-native requires a source object.')
      }
      await this.purgePreparedNativeSources()
      const prepared = await this.prepareSource(params.source)
      const token = randomUUID().replaceAll('-', '')
      const stagingPath = path.join(this.stagingDirectory, `native-${token}`)
      try {
        const archiveInfo = await stat(prepared.archivePath)
        if (!archiveInfo.isFile() || archiveInfo.size > MAXIMUM_ZIP_BYTES) {
          fail('zip-limit', 'The plugin ZIP exceeds the on-device size limit.')
        }
        const archiveEntries = await inspectArchive(prepared.archivePath)
        const extractionPlan = archiveExtractionPlan(archiveEntries, prepared.subpath)
        await extractArchive(prepared.archivePath, stagingPath, extractionPlan)
        const nativeCandidate = await makeNativeCompilationCandidate(
          stagingPath,
          prepared.publicSource,
          'native-first-analysis',
        ).catch(() => undefined)
        this.preparedNativeSources.set(token, {
          ...prepared,
          createdAt: Date.now(),
        })
        await this.purgePreparedNativeSources()
        return {
          preparedToken: token,
          ...(nativeCandidate === undefined ? {} : { nativeCandidate }),
        }
      } catch (error) {
        await this.releasePreparedSource(prepared)
        throw error
      } finally {
        await rm(stagingPath, { recursive: true, force: true }).catch(() => {})
      }
    })
  }

  async discardPreparedNative(token) {
    return await this.serialize(async () => {
      if (typeof token !== 'string' || !/^[a-f0-9]{32}$/.test(token)) {
        fail('invalid-prepared-source', 'The prepared native source token is invalid.')
      }
      const prepared = this.preparedNativeSources.get(token)
      this.preparedNativeSources.delete(token)
      await this.releasePreparedSource(prepared)
      return { ok: true }
    })
  }

  async prepareSource(source) {
    const kind = source.kind
    const location = source.location
    if (!['market', 'github', 'localZip'].includes(kind) || typeof location !== 'string') {
      fail('invalid-source', 'source.kind must be market, github, or localZip.')
    }
    if (kind === 'localZip') {
      const importsReal = await realpath(this.importsDirectory).catch(() => undefined)
      const sourceReal = await realpath(location).catch(() => undefined)
      if (importsReal === undefined || sourceReal === undefined || !isContained(sourceReal, importsReal)) {
        fail('invalid-source', 'Local ZIP files must be staged by the native document importer.')
      }
      const info = await lstat(sourceReal)
      if (!info.isFile() || info.isSymbolicLink() || info.size > MAXIMUM_ZIP_BYTES) {
        fail('invalid-source', 'The staged plugin ZIP is not a bounded regular file.')
      }
      return {
        archivePath: sourceReal,
        temporaryArchive: false,
        cleanupSource: sourceReal,
        publicSource: {
          kind,
          location: path.basename(sourceReal),
        },
      }
    }
    const github = parseGitHubLocation(location)
    const archivePath = path.join(this.downloadsDirectory, `${randomUUID()}.zip`)
    // GitHub's HEAD archive endpoint is convenient but is not available for
    // every repository mirror. For an unpinned repository, retry a 404 with
    // the conventional branches. Network/TLS failures are not retried here;
    // the transport layer already tried every on-device network path and a
    // second request would only add another minute of waiting.
    const refs = github.ref === undefined
      ? ['HEAD', 'main', 'master']
      : [github.ref]
    let selectedRef
    let lastError
    for (const ref of refs) {
      const archiveURL = `https://codeload.github.com/${github.owner}/${github.repository}/zip/${encodeURIComponent(ref)}`
      try {
        await downloadFile(archiveURL, archivePath)
        selectedRef = ref
        break
      } catch (error) {
        lastError = error
        if (github.ref !== undefined || !isNotFoundDownloadError(error) || ref === refs.at(-1)) {
          throw error
        }
      }
    }
    if (selectedRef === undefined) {
      throw lastError ?? new MarketplaceError(
        'download-failed',
        'The plugin repository has no downloadable HEAD, main, or master branch.',
      )
    }
    return {
      archivePath,
      temporaryArchive: true,
      subpath: github.subpath,
      publicSource: {
        kind,
        location: github.canonicalURL,
        repositoryURL: github.canonicalURL,
        repositoryKey: github.repositoryKey,
        ...(github.ref === undefined ? { ref: selectedRef } : { ref: github.ref }),
        ...(github.subpath === undefined ? {} : { subpath: github.subpath }),
      },
    }
  }

  npmEnvironment() {
    return {
      npm_config_cache: this.npmCacheDirectory,
      npm_config_ignore_scripts: 'true',
      npm_config_audit: 'false',
      npm_config_fund: 'false',
      npm_config_update_notifier: 'false',
    }
  }

  runtimeManifest(records) {
    const dependencies = {}
    for (const record of [...records].sort((left, right) => left.name.localeCompare(right.name))) {
      const tarball = path.resolve(this.root, ...record.tarball.split('/'))
      if (!isContained(tarball, this.root)) fail('invalid-registry', 'A plugin tarball path escapes plugin-market.')
      const relative = path.relative(this.runtimeDirectory, tarball).split(path.sep).join('/')
      dependencies[record.name] = `file:${relative.startsWith('.') ? relative : `./${relative}`}`
    }
    return {
      name: 'harness-mobile-ish-community-runtime',
      version: '1.0.0',
      private: true,
      type: 'module',
      dependencies,
    }
  }

  async writeRuntimeManifest(records) {
    await atomicWriteJSON(this.runtimeManifestPath, this.runtimeManifest(records))
  }

  async reconcileRuntime(records) {
    await this.writeRuntimeManifest(records)
    let lastResult
    for (const registry of ALLOWED_NPM_REGISTRIES) {
      const result = await runProcess(this.npmExecutable, [
        'install',
        '--ignore-scripts',
        '--legacy-peer-deps',
        '--omit=dev',
        '--no-audit',
        '--no-fund',
        '--prefer-offline',
        '--package-lock=true',
        '--registry',
        registry,
      ], {
        cwd: this.runtimeDirectory,
        env: this.npmEnvironment(),
      })
      if (result.code === 0) {
        await scanForNativeAddons(path.join(this.runtimeDirectory, 'node_modules'))
        await this.healHostPackages()
        for (const record of records) await this.validateRuntimeEntryPackages(record.entries)
        return
      }
      lastResult = result
    }
    fail('npm-install-failed', lastResult?.stderr.trim() || lastResult?.stdout.trim() || 'npm install failed.')
  }

  async healHostPackages() {
    const hostScope = path.join(this.hostDirectory, 'node_modules', '@deepseek-ai')
    if (!await directoryExists(hostScope)) return
    const runtimeScope = path.join(this.runtimeDirectory, 'node_modules', '@deepseek-ai')
    await mkdir(runtimeScope, { recursive: true, mode: 0o700 })
    const stream = await opendir(hostScope)
    for await (const entry of stream) {
      if (!entry.isDirectory() && !entry.isSymbolicLink()) continue
      const source = path.join(hostScope, entry.name)
      const destination = path.join(runtimeScope, entry.name)
      await rm(destination, { recursive: true, force: true })
      await symlink(source, destination, 'dir')
    }
  }

  async validateRuntimeEntryPackages(entries) {
    const packages = new Map()
    const collect = (entry) => {
      const packageName = validateBareSpecifier(entry.name, `entry ${entry.id}`)
      if (packageName !== undefined) {
        const specifiers = packages.get(packageName) ?? new Set()
        specifiers.add(entry.name)
        packages.set(packageName, specifiers)
      }
      if (entry.group === true) entry.config.forEach(collect)
    }
    entries.forEach(collect)
    const anchor = this.runtimeManifestPath
    for (const [packageName, specifiers] of packages) {
      const directory = packageDirectoryFromAnchor(anchor, packageName)
      if (directory === undefined) fail('missing-package', `Runtime package ${JSON.stringify(packageName)} is not installed.`)
      const manifest = await readJSONFile(path.join(directory, 'package.json'))
      await validateDeclaredPackageEntrypoint(directory, manifest, packageName, entries, specifiers)
    }
  }

  async load(record) {
    if (this.loadedGroups.has(record.id)) return
    const groupID = `market-${record.id}`
    try {
      await this.ctx.loader.create({
        id: groupID,
        name: 'cordis:group',
        group: true,
        config: structuredClone(record.entries),
      })
      await this.ctx.loader.await()
      const activationGeneration = this.nextActivationGeneration
      this.nextActivationGeneration += 1
      this.loadedGroups.set(record.id, { groupID, activationGeneration })
    } catch (error) {
      try { await this.ctx.loader.remove(groupID) } catch {}
      throw error
    }
  }

  async unload(id) {
    const activation = this.loadedGroups.get(id)
    if (activation === undefined) return
    await this.ctx.loader.remove(activation.groupID)
    await this.ctx.loader.await()
    this.loadedGroups.delete(id)
  }

  async removeRecordStorage(record) {
    for (const relative of [record.directory, record.tarball]) {
      if (typeof relative !== 'string') continue
      const target = path.resolve(this.root, ...relative.split('/'))
      if (!isContained(target, this.root)) continue
      await rm(target, { recursive: true, force: true }).catch(() => {})
    }
  }
}

export function loaderBaseURL(workspaceRoot) {
  const runtime = path.resolve(workspaceRoot, '.harness-mobile', 'plugin-market', 'runtime')
  return pathToFileURL(runtime).href.replace(/\/?$/, '/')
}
