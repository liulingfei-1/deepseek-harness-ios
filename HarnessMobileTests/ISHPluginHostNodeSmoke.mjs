import assert from 'node:assert/strict'
import { spawn } from 'node:child_process'
import { once } from 'node:events'
import {
  mkdir,
  mkdtemp,
  rm,
  stat,
  symlink,
  writeFile,
} from 'node:fs/promises'
import os from 'node:os'
import path from 'node:path'
import { pathToFileURL } from 'node:url'

const hostDirectory = process.argv[2]
if (hostDirectory === undefined) {
  throw new Error('usage: node ISHPluginHostNodeSmoke.mjs <installed-host-directory>')
}

const resolvedHostDirectory = path.resolve(hostDirectory)
const workspaceRoot = await mkdtemp(path.join(os.tmpdir(), 'harness-mobile-plugin-host-'))
const importsDirectory = path.join(workspaceRoot, '.harness-mobile', 'plugin-imports')
await mkdir(importsDirectory, { recursive: true })

const child = spawn(process.execPath, ['--jitless', '--expose-internals', 'host.mjs'], {
  cwd: resolvedHostDirectory,
  env: {
    ...process.env,
    HARNESS_MOBILE_WORKSPACE: workspaceRoot,
  },
  stdio: ['pipe', 'pipe', 'inherit'],
})
const pending = new Map()
let nextId = 1
let stdoutBuffer = ''

child.stdout.setEncoding('utf8')
child.stdout.on('data', (chunk) => {
  stdoutBuffer += chunk
  for (;;) {
    const newline = stdoutBuffer.indexOf('\n')
    if (newline < 0) break
    const line = stdoutBuffer.slice(0, newline)
    stdoutBuffer = stdoutBuffer.slice(newline + 1)
    if (line.length === 0) continue
    const response = JSON.parse(line)
    const waiter = pending.get(String(response.id))
    if (waiter === undefined) continue
    pending.delete(String(response.id))
    if (response.error !== undefined) {
      const error = new Error(`${response.error.code}: ${response.error.message}`)
      error.rpc = response.error
      waiter.reject(error)
    } else {
      waiter.resolve(response.result)
    }
  }
})

function rpc(method, params = {}) {
  const id = String(nextId++)
  return new Promise((resolve, reject) => {
    pending.set(id, { resolve, reject })
    child.stdin.write(`${JSON.stringify({ jsonrpc: '2.0', id, method, params })}\n`)
  })
}

async function runCommand(command, args, options = {}) {
  const process = spawn(command, args, {
    cwd: options.cwd,
    stdio: ['ignore', 'pipe', 'pipe'],
  })
  let stdout = ''
  let stderr = ''
  process.stdout.setEncoding('utf8')
  process.stderr.setEncoding('utf8')
  process.stdout.on('data', chunk => { stdout += chunk })
  process.stderr.on('data', chunk => { stderr += chunk })
  const [code] = await once(process, 'exit')
  if (code !== 0) {
    throw new Error(`${command} failed (${code}): ${stderr || stdout}`)
  }
}

function validPatch(packageName, entryID) {
  return `- insert:\n    - id: ${entryID}\n      name: '${packageName}'\n`
}

function pluginSource(version, { failOnApply = false } = {}) {
  if (failOnApply) {
    return `export function apply() { throw new Error('replacement failure ${version}') }\n`
  }
  return `
import { defineTool } from '@deepseek-ai/dsh-tools'
import z from '@deepseek-ai/schemastery'

export const name = 'market-smoke'
export const inject = ['tools', 'systemPrompt', 'settings']

export function apply(ctx) {
  ctx.provide('marketSmokeInspector', {
    status(args) {
      return {
        version: '${version}',
        state: 'active',
        query: args,
      }
    },
  })
  ctx.settings.register('market-smoke', z.object({
    enabled: z.boolean().default(true).description('Enabled'),
    count: z.number().min(0).max(10).step(1).default(1),
    mode: z.union([
      z.const('fast').description('Fast'),
      z.const('safe').description('Safe'),
    ]).default('safe'),
    nested: z.object({ label: z.string().default('phone') }),
    token: z.string().role('secret'),
  }))
  ctx.settings.register('market-smoke-complex', z.object({
    computed: z.transform(z.string().default('x'), value => value.toUpperCase()),
  }))
  ctx.tools.register(defineTool({
    name: 'market_smoke_echo',
    description: 'Return the marketplace fixture version and text.',
    parameters: { text: { type: 'string' } },
    output: {
      schema: { type: 'string' },
      render(_args, value) { return [{ type: 'text', text: value }] },
    },
    async execute(args) { return '${version}:' + String(args.text ?? '') },
  }))
  ctx.systemPrompt.section({
    name: 'market:smoke',
    order: 170,
    text: 'Marketplace smoke plugin ${version} is active.',
  })
}
`
}

function nativeClientManifest({ renderer = 'keyValue', secretArguments = false } = {}) {
  return {
    schemaVersion: 1,
    minimumRuntime: 1,
    contributions: {
      inspectors: [{
        id: 'status',
        title: 'Status',
        description: 'Read the active Host service state.',
        order: 10,
        renderer,
        endpoint: 'status',
      }],
      settings: [{
        id: 'settings',
        title: 'Market Smoke Settings',
        namespace: 'market-smoke',
        order: 20,
      }],
      commands: [{
        name: 'market_status',
        description: 'Invoke the market smoke Host tool.',
        inputHint: '<text>',
        order: 30,
        action: {
          kind: 'hostTool',
          name: 'market_smoke_echo',
          arguments: secretArguments ? { apiKey: 'not-even-a-real-key' } : {},
          inputKey: 'text',
        },
      }],
    },
    endpoints: [{
      id: 'status',
      kind: 'hostService',
      entry: 'market-smoke',
      service: 'marketSmokeInspector',
      method: 'status',
      readOnly: true,
    }],
    permissions: [
      'host.service:marketSmokeInspector.status',
      'host.tool:market_smoke_echo',
      'settings.read:market-smoke',
      'ui.command',
      'ui.inspector',
      'ui.settings-link',
    ],
  }
}

async function createPluginArchive({
  archiveName,
  packageName,
  version = '1.0.0',
  main = './index.js',
  patch = validPatch(packageName, archiveName.replace(/[^A-Za-z0-9._-]/g, '-')),
  source = 'export function apply() {}\n',
  client = false,
  nativeClient,
  nativeAddon = false,
  symbolicLink = false,
}) {
  const sourceRoot = await mkdtemp(path.join(os.tmpdir(), 'harness-mobile-plugin-fixture-'))
  const manifest = {
    name: packageName,
    version,
    type: 'module',
    main,
    scripts: {
      install: "node -e \"require('node:fs').writeFileSync('lifecycle-ran', 'unsafe')\"",
    },
    dsh: {
      bundle: { patch: './cordis.patch.yml' },
      ...(client ? { client: './client.js' } : {}),
      ...(nativeClient === undefined ? {} : {
        nativeClient: {
          schemaVersion: 1,
          platform: 'ios-native',
          manifest: './native-client.json',
          inject: [],
          immediately: false,
        },
      }),
    },
  }
  await Promise.all([
    writeFile(path.join(sourceRoot, 'package.json'), `${JSON.stringify(manifest, null, 2)}\n`),
    writeFile(path.join(sourceRoot, 'cordis.patch.yml'), patch),
    writeFile(path.join(sourceRoot, 'index.js'), source),
    ...(client ? [writeFile(path.join(sourceRoot, 'client.js'), 'export function apply() {}\n')] : []),
    ...(nativeClient === undefined ? [] : [
      writeFile(path.join(sourceRoot, 'native-client.json'), `${JSON.stringify(nativeClient, null, 2)}\n`),
    ]),
    ...(nativeAddon ? [writeFile(path.join(sourceRoot, 'fixture.node'), Buffer.from('not-a-native-binary'))] : []),
  ])
  if (symbolicLink) {
    await symlink('index.js', path.join(sourceRoot, 'linked-index.js'))
  }
  const archivePath = path.join(importsDirectory, `${archiveName}.zip`)
  await runCommand('/usr/bin/zip', [symbolicLink ? '-qry' : '-qr', archivePath, '.'], {
    cwd: sourceRoot,
  })
  await rm(sourceRoot, { recursive: true, force: true })
  return archivePath
}

try {
  const ping = await rpc('ping')
  assert.equal(ping.packages['@deepseek-ai/cordis'], '4.0.1')
  assert.equal(ping.packages['@deepseek-ai/dsh-tool-cordis'], '0.1.0-rc.6')
  assert.ok(ping.capabilities.includes('plugin/prepare-native'))
  assert.ok(ping.capabilities.includes('plugin/discard-prepared-native'))

  const initialContributions = await rpc('contributions', { sessionId: 'smoke-session' })
  const officialCordisTools = [
    'cordis_inspect_list',
    'cordis_inspect_query',
    'cordis_inspect_self',
    'cordis_define',
    'cordis_run',
    'cordis_stop',
    'cordis_undefine',
  ]
  for (const name of officialCordisTools) {
    assert.ok(initialContributions.tools.some(tool => tool.name === name), `missing ${name}`)
  }
  assert.ok(initialContributions.prompt.sections.some(section => section.name === 'tool:cordis'))
  assert.ok(initialContributions.prompt.sections.some(section => section.name === 'mobile:cordis-host-policy'))

  const inspectedProviders = await rpc('invoke', {
    target: 'tool',
    sessionId: 'smoke-session',
    name: 'cordis_inspect_list',
    arguments: {},
  })
  assert.equal(inspectedProviders.isError, false)
  assert.ok(inspectedProviders.value.providers.some(provider => provider.platform === 'host'))
  const inspectedTools = await rpc('invoke', {
    target: 'tool',
    sessionId: 'smoke-session',
    name: 'cordis_inspect_query',
    arguments: {
      platform: 'host',
      provider: 'Tool',
      method: 'listTools',
      input: {},
    },
  })
  assert.equal(inspectedTools.isError, false)
  assert.ok(inspectedTools.value.data.tools.some(tool => tool.name === 'cordis_define'))

  const officialDefinition = await rpc('invoke', {
    target: 'tool',
    sessionId: 'smoke-session',
    name: 'cordis_define',
    arguments: {
      plugin: { kind: 'new', idPrefix: 'self' },
      name: 'official-self-tool',
      purpose: 'Verify the official Cordis tool lifecycle',
      code: {
        host: `
          return {
            name: 'official-self-tool',
            inject: ['tools'],
            apply(ctx) {
              harness.registerTool(ctx, harness.defineTool({
                name: 'official_echo',
                description: 'Return the supplied text.',
                parameters: { text: { type: 'string', required: true } },
                output: {
                  schema: { type: 'string' },
                  render(_args, value) { return [{ type: 'text', text: value }] },
                },
                async execute(args) { return args.text },
              }))
            },
          }
        `,
      },
    },
  })
  assert.equal(officialDefinition.isError, false)
  const officialInspection = await rpc('invoke', {
    target: 'tool',
    sessionId: 'smoke-session',
    name: 'cordis_inspect_self',
    arguments: {
      pluginId: officialDefinition.value.pluginId,
      packageId: officialDefinition.value.packageId,
    },
  })
  assert.equal(officialInspection.isError, false)
  assert.equal(officialInspection.value.mode, 'package')
  assert.match(officialInspection.value.code.host, /official_echo/)
  const officialRun = await rpc('invoke', {
    target: 'tool',
    sessionId: 'smoke-session',
    name: 'cordis_run',
    arguments: {
      pluginId: officialDefinition.value.pluginId,
      packageId: officialDefinition.value.packageId,
      mode: 'run',
    },
  })
  assert.equal(officialRun.isError, false)
  assert.equal(officialRun.value.status, 'running')
  const officialEcho = await rpc('invoke', {
    target: 'tool',
    sessionId: 'smoke-session',
    name: 'official_echo',
    arguments: { text: 'on-device' },
  })
  assert.equal(officialEcho.isError, false)
  assert.equal(officialEcho.value, 'on-device')
  const officialStop = await rpc('invoke', {
    target: 'tool',
    sessionId: 'smoke-session',
    name: 'cordis_stop',
    arguments: { pluginId: officialDefinition.value.pluginId },
  })
  assert.equal(officialStop.isError, false)
  const officialRemove = await rpc('invoke', {
    target: 'tool',
    sessionId: 'smoke-session',
    name: 'cordis_undefine',
    arguments: { pluginId: officialDefinition.value.pluginId },
  })
  assert.equal(officialRemove.isError, false)

  await assert.rejects(
    rpc('define', {
      sessionId: 'smoke-session',
      plugin: { kind: 'new', idPrefix: 'deny' },
      name: 'credential-probe',
      purpose: 'Must be rejected before definition',
      code: { host: "return { name: 'sk-1234567890abcdef', apply() {} }" },
    }),
    /-32001:/,
  )

  const defined = await rpc('define', {
    sessionId: 'smoke-session',
    plugin: { kind: 'new', idPrefix: 'probe' },
    name: 'reverse-tool',
    purpose: 'Node smoke test',
    code: {
      host: `
        return {
          name: 'reverse-tool',
          inject: ['tools'],
          apply(ctx) {
            harness.handle('uppercase', args => String(args.text).toUpperCase())
            harness.handle('agent/pre-step', args => ({
              kind: 'enter',
              messages: args.messages,
            }))
            ctx.provide('memory', {
              recall(args) {
                return { kind: 'enter', messages: args.messages }
              },
              record(args) {
                return { kind: 'recorded', step: args.step, version: 1 }
              },
            })
            harness.registerTool(ctx, harness.defineTool({
              name: 'reverse_text',
              description: 'Reverse a string.',
              parameters: { text: { type: 'string', required: true } },
              output: {
                schema: { type: 'string' },
                render(_args, value) { return [{ type: 'text', text: value }] },
              },
              async execute(args) { return args.text.split('').reverse().join('') },
            }))
          },
        }
      `,
    },
  })

  const run = await rpc('run', {
    sessionId: 'smoke-session',
    pluginId: defined.pluginId,
    packageId: defined.packageId,
    mode: 'run',
  })
  assert.equal(run.ok, true)

  const contributions = await rpc('contributions', { sessionId: 'smoke-session' })
  assert.ok(contributions.tools.some(tool => tool.name === 'reverse_text'))
  assert.equal(contributions.scope, 'session')
  assert.ok(contributions.handlers.some(handler => (
    handler.pluginId === defined.pluginId
      && handler.pluginRunId === run.pluginRunId
      && handler.method === 'agent/pre-step'
  )))
  const memory = contributions.services.find(service => (
    service.pluginId === defined.pluginId
      && service.pluginRunId === run.pluginRunId
      && service.name === 'memory'
  ))
  assert.deepEqual(memory?.methods, ['recall', 'record'])

  const invoked = await rpc('invoke', {
    target: 'tool',
    sessionId: 'smoke-session',
    name: 'reverse_text',
    arguments: { text: 'Cordis' },
  })
  assert.equal(invoked.isError, false)
  assert.equal(invoked.value, 'sidroC')
  const handled = await rpc('invoke', {
    target: 'handler',
    sessionId: 'smoke-session',
    pluginId: defined.pluginId,
    pluginRunId: run.pluginRunId,
    method: 'uppercase',
    arguments: { text: 'Cordis' },
  })
  assert.equal(handled.ok, true)
  assert.equal(handled.value, 'CORDIS')

  const checkpointHandled = await rpc('invoke', {
    target: 'handler',
    sessionId: 'smoke-session',
    pluginId: defined.pluginId,
    pluginRunId: run.pluginRunId,
    method: 'agent/pre-step',
    arguments: { messages: [{ role: 'user', content: 'hello' }] },
  })
  assert.equal(checkpointHandled.ok, true)
  assert.equal(checkpointHandled.value.kind, 'enter')

  const memoryRecorded = await rpc('invoke', {
    target: 'service',
    sessionId: 'smoke-session',
    pluginId: defined.pluginId,
    pluginRunId: run.pluginRunId,
    service: 'memory',
    method: 'record',
    arguments: { step: 3 },
  })
  assert.equal(memoryRecorded.ok, true)
  assert.deepEqual(memoryRecorded.value, { kind: 'recorded', step: 3, version: 1 })

  const updated = await rpc('define', {
    sessionId: 'smoke-session',
    plugin: { kind: 'existing', pluginId: defined.pluginId },
    name: 'reverse-tool-v2',
    purpose: 'Verify stale run isolation after update',
    code: {
      host: `
        return {
          name: 'reverse-tool-v2',
          apply(ctx) {
            harness.handle('uppercase', args => String(args.text).toLowerCase())
            harness.handle('agent/pre-step', args => ({ kind: 'enter', messages: args.messages }))
            ctx.provide('memory', {
              recall(args) { return { kind: 'enter', messages: args.messages } },
              record(args) { return { kind: 'recorded', step: args.step, version: 2 } },
            })
          },
        }
      `,
    },
  })
  const updatedRun = await rpc('run', {
    sessionId: 'smoke-session',
    pluginId: defined.pluginId,
    packageId: updated.packageId,
    mode: 'update',
  })
  assert.equal(updatedRun.ok, true)
  assert.notEqual(updatedRun.pluginRunId, run.pluginRunId)

  const staleHandler = await rpc('invoke', {
    target: 'handler',
    sessionId: 'smoke-session',
    pluginId: defined.pluginId,
    pluginRunId: run.pluginRunId,
    method: 'uppercase',
    arguments: { text: 'Cordis' },
  })
  assert.equal(staleHandler.ok, false)
  assert.equal(staleHandler.code, 'stale-run')
  const staleService = await rpc('invoke', {
    target: 'service',
    sessionId: 'smoke-session',
    pluginId: defined.pluginId,
    pluginRunId: run.pluginRunId,
    service: 'memory',
    method: 'record',
    arguments: { step: 4 },
  })
  assert.equal(staleService.ok, false)
  assert.equal(staleService.code, 'stale-run')

  const updatedHandled = await rpc('invoke', {
    target: 'handler',
    sessionId: 'smoke-session',
    pluginId: defined.pluginId,
    pluginRunId: updatedRun.pluginRunId,
    method: 'uppercase',
    arguments: { text: 'Cordis' },
  })
  assert.equal(updatedHandled.ok, true)
  assert.equal(updatedHandled.value, 'cordis')
  const updatedMemory = await rpc('invoke', {
    target: 'service',
    sessionId: 'smoke-session',
    pluginId: defined.pluginId,
    pluginRunId: updatedRun.pluginRunId,
    service: 'memory',
    method: 'record',
    arguments: { step: 5 },
  })
  assert.equal(updatedMemory.ok, true)
  assert.equal(updatedMemory.value.version, 2)

  const stopped = await rpc('stop', {
    sessionId: 'smoke-session',
    pluginId: defined.pluginId,
  })
  assert.equal(stopped.ok, true)

  const afterStop = await rpc('contributions', { sessionId: 'smoke-session' })
  assert.ok(!afterStop.tools.some(tool => tool.name === 'reverse_text'))
  assert.ok(!afterStop.handlers.some(handler => handler.pluginId === defined.pluginId))
  assert.ok(!afterStop.services.some(service => service.pluginId === defined.pluginId))

  const stoppedHandler = await rpc('invoke', {
    target: 'handler',
    sessionId: 'smoke-session',
    pluginId: defined.pluginId,
    pluginRunId: updatedRun.pluginRunId,
    method: 'uppercase',
    arguments: { text: 'Cordis' },
  })
  assert.equal(stoppedHandler.ok, false)
  assert.equal(stoppedHandler.code, 'plugin-not-running')
  const stoppedService = await rpc('invoke', {
    target: 'service',
    sessionId: 'smoke-session',
    pluginId: defined.pluginId,
    pluginRunId: updatedRun.pluginRunId,
    service: 'memory',
    method: 'record',
    arguments: { step: 6 },
  })
  assert.equal(stoppedService.ok, false)
  assert.equal(stoppedService.code, 'plugin-not-running')

  const removed = await rpc('undefine', {
    sessionId: 'smoke-session',
    pluginId: defined.pluginId,
  })
  assert.equal(removed.ok, true)

  const inventory = await rpc('inventory', { sessionId: 'smoke-session' })
  assert.equal(inventory.entries.length, 0)

  const clientDefinition = await rpc('define', {
    sessionId: 'smoke-session',
    plugin: { kind: 'new', idPrefix: 'view' },
    name: 'client-half-probe',
    purpose: 'Verify native client-runner boundary',
    code: { client: 'return { name: "view", apply() {} }' },
  })
  const officialClientRun = await rpc('invoke', {
    target: 'tool',
    sessionId: 'smoke-session',
    name: 'cordis_run',
    arguments: {
      pluginId: clientDefinition.pluginId,
      packageId: clientDefinition.packageId,
      mode: 'run',
    },
  })
  assert.equal(officialClientRun.isError, true)
  assert.match(JSON.stringify(officialClientRun), /Client runner/)
  await assert.rejects(
    rpc('run', {
      sessionId: 'smoke-session',
      pluginId: clientDefinition.pluginId,
      packageId: clientDefinition.packageId,
      mode: 'run',
    }),
    /-32002:/,
  )
  await rpc('undefine', {
    sessionId: 'smoke-session',
    pluginId: clientDefinition.pluginId,
  })

  const {
    MarketplaceError,
    MarketplaceManager,
    parseGitHubLocation,
    validateArchiveEntryName,
  } = await import(pathToFileURL(path.join(resolvedHostDirectory, 'marketplace.mjs')).href)
  assert.throws(
    () => validateArchiveEntryName('../zip-slip.txt'),
    error => error instanceof MarketplaceError && error.code === 'invalid-zip',
  )
  assert.equal(
    parseGitHubLocation('https://github.com/example/plugin/tree/main/packages/mobile').archiveURL,
    'https://codeload.github.com/example/plugin/zip/main',
  )

  const originalFetch = globalThis.fetch
  const marketFetches = []
  globalThis.fetch = async url => {
    marketFetches.push(String(url))
    if (String(url).includes('cdn.jsdelivr.net')) {
      const error = new TypeError('fetch failed')
      error.cause = Object.assign(new Error('mirror unavailable'), { code: 'ENETUNREACH' })
      throw error
    }
    const markdown = '### 工具与能力\n- [Fallback plugin](https://github.com/example/fallback-plugin) — Local Host fallback\n'
    const bytes = Buffer.from(markdown)
    let consumed = false
    return {
      ok: true,
      status: 200,
      url: String(url),
      body: {
        getReader() {
          return {
            async read() {
              if (consumed) return { done: true, value: undefined }
              consumed = true
              return { done: false, value: new Uint8Array(bytes) }
            },
            async cancel() {},
          }
        },
      },
    }
  }
  const marketWorkspace = await mkdtemp(path.join(os.tmpdir(), 'harness-mobile-market-fallback-'))
  try {
    const orphanPlugin = path.join(
      marketWorkspace,
      '.harness-mobile',
      'plugin-market',
      'plugins',
      'orphan-interrupted-install',
    )
    const orphanPackage = path.join(
      marketWorkspace,
      '.harness-mobile',
      'plugin-market',
      'packages',
      'orphan-interrupted-install.tgz',
    )
    await mkdir(orphanPlugin, { recursive: true })
    await mkdir(path.dirname(orphanPackage), { recursive: true })
    await writeFile(path.join(orphanPlugin, 'package.json'), '{}\n')
    await writeFile(orphanPackage, 'interrupted')
    const market = new MarketplaceManager({}, {
      workspaceRoot: marketWorkspace,
      hostDirectory: resolvedHostDirectory,
    })
    await market.start()
    await assert.rejects(stat(orphanPlugin), error => error?.code === 'ENOENT')
    await assert.rejects(stat(orphanPackage), error => error?.code === 'ENOENT')
    const fallbackCatalog = await market.catalog({ forceRefresh: true })
    // Native HTTPS can satisfy the first mirror after the mocked Undici
    // failure, so only assert the deterministic first attempt here.
    assert.equal(
      marketFetches[0],
      'https://cdn.jsdelivr.net/gh/awesome-dsh-plugin/awesome-dsh-plugin@main/README.zh.md',
    )
    assert.ok(fallbackCatalog.items.length > 0)
  } finally {
    globalThis.fetch = originalFetch
    await rm(marketWorkspace, { recursive: true, force: true })
  }

  const marketPackageName = '@harness-mobile/market-smoke'
  const firstArchive = await createPluginArchive({
    archiveName: 'market-smoke-v1',
    packageName: marketPackageName,
    version: '1.0.0',
    patch: validPatch(marketPackageName, 'market-smoke'),
    source: pluginSource('1.0.0'),
    client: true,
    nativeClient: nativeClientManifest(),
  })
  const preparedFirst = await rpc('plugin/prepare-native', {
    source: { kind: 'localZip', location: firstArchive },
  })
  assert.match(preparedFirst.preparedToken, /^[a-f0-9]{32}$/)
  assert.equal(preparedFirst.nativeCandidate.packageName, marketPackageName)
  assert.ok(preparedFirst.nativeCandidate.files.some(file => file.path === 'package.json'))
  const installed = await rpc('plugin/install', {
    source: { kind: 'localZip', location: firstArchive },
    preparedToken: preparedFirst.preparedToken,
  })
  assert.equal(installed.plugin.name, marketPackageName)
  assert.equal(installed.plugin.version, '1.0.0')
  assert.equal(installed.plugin.enabled, false)
  assert.equal(installed.plugin.state, 'disabled')
  const marketPluginID = installed.plugin.id

  const contributionsWhileDisabled = await rpc('contributions', { sessionId: 'smoke-session' })
  assert.ok(!contributionsWhileDisabled.tools.some(tool => tool.name === 'market_smoke_echo'))
  assert.ok(!contributionsWhileDisabled.prompt.sections.some(section => section.name === 'market:smoke'))
  assert.deepEqual(contributionsWhileDisabled.nativeClient.plugins, [])

  const enabled = await rpc('plugin/set-enabled', { id: marketPluginID, enabled: true })
  assert.equal(enabled.plugin.enabled, true)
  assert.equal(enabled.plugin.state, 'enabled')
  const contributionsWhileEnabled = await rpc('contributions', { sessionId: 'smoke-session' })
  assert.ok(contributionsWhileEnabled.tools.some(tool => tool.name === 'market_smoke_echo'))
  assert.ok(contributionsWhileEnabled.prompt.sections.some(section => section.name === 'market:smoke'))
  assert.equal(contributionsWhileEnabled.nativeClient.scope, 'process')
  assert.equal(contributionsWhileEnabled.nativeClient.plugins.length, 1)
  const nativeClient = contributionsWhileEnabled.nativeClient.plugins[0]
  assert.equal(nativeClient.pluginId, marketPluginID)
  assert.equal(nativeClient.scope, 'process')
  assert.equal(nativeClient.contributions.inspectors[0].renderer, 'keyValue')
  assert.equal(nativeClient.contributions.settings[0].namespace, 'market-smoke')
  assert.equal(nativeClient.contributions.commands[0].name, 'market_status')
  assert.match(nativeClient.sourceDigest, /^[a-f0-9]{64}$/)
  const nativeEndpoint = await rpc('invoke', {
    target: 'nativeClientEndpoint',
    pluginId: marketPluginID,
    activationGeneration: nativeClient.activationGeneration,
    endpointId: 'status',
    arguments: { source: 'ios' },
  })
  assert.equal(nativeEndpoint.ok, true)
  assert.equal(nativeEndpoint.value.version, '1.0.0')
  assert.deepEqual(nativeEndpoint.value.query, { source: 'ios' })
  const settingsBeforeWrite = await rpc('settings/describe')
  assert.equal(settingsBeforeWrite.writable, true)
  assert.equal(settingsBeforeWrite.hasDocument, true)
  const safeSettings = settingsBeforeWrite.namespaces.find(entry => entry.ns === 'market-smoke')
  assert.equal(safeSettings.editable, true)
  assert.equal(safeSettings.revision, 0)
  assert.equal(safeSettings.value.count, 1)
  assert.equal(safeSettings.schema.refs[String(safeSettings.schema.uid)].dict.token, undefined)
  assert.deepEqual(safeSettings.secrets, [{ path: ['token'], set: false }])
  const complexSettings = settingsBeforeWrite.namespaces.find(entry => entry.ns === 'market-smoke-complex')
  assert.equal(complexSettings.editable, false)
  assert.equal(complexSettings.schema, null)

  const settingsAfterWrite = await rpc('settings/mutate', {
    ns: 'market-smoke',
    ops: [{ op: 'set', path: ['count'], value: 4 }],
    expectedRevision: safeSettings.revision,
  })
  assert.equal(settingsAfterWrite.revision, 1)
  assert.equal(settingsAfterWrite.value.count, 4)
  assert.deepEqual(settingsAfterWrite.user, { count: 4 })
  await assert.rejects(
    rpc('settings/mutate', {
      ns: 'market-smoke',
      ops: [{ op: 'set', path: ['count'], value: 5 }],
      expectedRevision: 0,
    }),
    error => error?.rpc?.data?.reason === 'settings-conflict'
      && error?.rpc?.data?.actualRevision === 1,
  )
  await assert.rejects(
    rpc('settings/mutate', {
      ns: 'market-smoke',
      ops: [{ op: 'set', path: ['token'], value: 'not-a-provider-key' }],
      expectedRevision: 1,
    }),
    /-32001:/,
  )
  const marketInvocation = await rpc('invoke', {
    target: 'tool',
    sessionId: 'smoke-session',
    name: 'market_smoke_echo',
    arguments: { text: 'phone' },
  })
  assert.equal(marketInvocation.isError, false)
  assert.equal(marketInvocation.value, '1.0.0:phone')
  const lifecycleMarker = path.join(
    workspaceRoot,
    '.harness-mobile',
    'plugin-market',
    'runtime',
    'node_modules',
    '@harness-mobile',
    'market-smoke',
    'lifecycle-ran',
  )
  await assert.rejects(stat(lifecycleMarker), error => error?.code === 'ENOENT')

  const replacementArchive = await createPluginArchive({
    archiveName: 'market-smoke-v2',
    packageName: marketPackageName,
    version: '2.0.0',
    patch: `${validPatch(marketPackageName, 'market-smoke')}
    - id: missing-runtime
      name: '@harness-mobile/missing-runtime'
`,
    source: pluginSource('2.0.0'),
  })
  await assert.rejects(
    rpc('plugin/install', {
      source: { kind: 'localZip', location: replacementArchive },
      replace: true,
    }),
    error => error?.rpc?.data?.reason === 'missing-package',
  )
  const afterFailedReplacement = await rpc('plugin/list')
  assert.equal(afterFailedReplacement.plugins.length, 1)
  assert.equal(afterFailedReplacement.plugins[0].id, marketPluginID)
  assert.equal(afterFailedReplacement.plugins[0].version, '1.0.0')
  assert.equal(afterFailedReplacement.plugins[0].state, 'enabled')
  const invocationAfterRollback = await rpc('invoke', {
    target: 'tool',
    sessionId: 'smoke-session',
    name: 'market_smoke_echo',
    arguments: { text: 'rollback' },
  })
  assert.equal(invocationAfterRollback.value, '1.0.0:rollback')
  await assert.rejects(
    rpc('invoke', {
      target: 'nativeClientEndpoint',
      pluginId: marketPluginID,
      activationGeneration: nativeClient.activationGeneration,
      endpointId: 'status',
      arguments: {},
    }),
    error => error?.rpc?.data?.reason === 'stale-generation',
  )
  const contributionsAfterRollback = await rpc('contributions', { sessionId: 'smoke-session' })
  const rolledBackNativeClient = contributionsAfterRollback.nativeClient.plugins[0]
  assert.notEqual(rolledBackNativeClient.activationGeneration, nativeClient.activationGeneration)
  const nativeEndpointAfterRollback = await rpc('invoke', {
    target: 'nativeClientEndpoint',
    pluginId: marketPluginID,
    activationGeneration: rolledBackNativeClient.activationGeneration,
    endpointId: 'status',
    arguments: {},
  })
  assert.equal(nativeEndpointAfterRollback.value.version, '1.0.0')

  const clientOnlyArchive = await createPluginArchive({
    archiveName: 'client-only',
    packageName: '@harness-mobile/client-probe',
    client: true,
  })
  const clientDeclared = await rpc('plugin/install', {
    source: { kind: 'localZip', location: clientOnlyArchive },
  })
  assert.equal(clientDeclared.plugin.state, 'disabled')
  const clientDeclaredEnabled = await rpc('plugin/set-enabled', {
    id: clientDeclared.plugin.id,
    enabled: true,
  })
  assert.equal(clientDeclaredEnabled.plugin.state, 'enabled')
  const clientDeclaredContributions = await rpc('contributions', { sessionId: 'smoke-session' })
  assert.deepEqual(
    clientDeclaredContributions.nativeClient.plugins.map(plugin => plugin.pluginId),
    [marketPluginID],
  )
  await rpc('plugin/uninstall', { id: clientDeclared.plugin.id })

  const missingEntrypointArchive = await createPluginArchive({
    archiveName: 'missing-entrypoint',
    packageName: '@harness-mobile/missing-entrypoint',
    main: './lib/index.js',
  })
  const preparedMissingEntrypoint = await rpc('plugin/prepare-native', {
    source: { kind: 'localZip', location: missingEntrypointArchive },
  })
  assert.match(preparedMissingEntrypoint.preparedToken, /^[a-f0-9]{32}$/)
  assert.equal(preparedMissingEntrypoint.nativeCandidate.schemaVersion, 1)
  assert.equal(preparedMissingEntrypoint.nativeCandidate.failureReason, 'native-first-analysis')
  assert.match(preparedMissingEntrypoint.nativeCandidate.sourceDigest, /^[a-f0-9]{64}$/)
  assert.ok(preparedMissingEntrypoint.nativeCandidate.files.some(file => file.path.endsWith('package.json')))
  await assert.rejects(
    rpc('plugin/install', {
      source: { kind: 'localZip', location: missingEntrypointArchive },
      preparedToken: preparedMissingEntrypoint.preparedToken,
    }),
    error => {
      const candidate = error?.rpc?.data?.nativeCandidate
      return error?.rpc?.data?.reason === 'missing-entrypoint'
        && candidate?.schemaVersion === 1
        && candidate?.failureReason === 'missing-entrypoint'
        && /^[a-f0-9]{64}$/.test(candidate?.sourceDigest ?? '')
        && candidate?.files?.some(file => file.path.endsWith('package.json'))
    },
  )

  const unknownNativeTypeArchive = await createPluginArchive({
    archiveName: 'native-unknown-renderer',
    packageName: '@harness-mobile/native-unknown-renderer',
    patch: validPatch('@harness-mobile/native-unknown-renderer', 'market-smoke'),
    nativeClient: nativeClientManifest({ renderer: 'webComponent' }),
  })
  await assert.rejects(
    rpc('plugin/install', { source: { kind: 'localZip', location: unknownNativeTypeArchive } }),
    error => error?.rpc?.data?.reason === 'invalid-native-client',
  )

  const credentialNativeArchive = await createPluginArchive({
    archiveName: 'native-credential',
    packageName: '@harness-mobile/native-credential',
    patch: validPatch('@harness-mobile/native-credential', 'market-smoke'),
    nativeClient: nativeClientManifest({ secretArguments: true }),
  })
  await assert.rejects(
    rpc('plugin/install', { source: { kind: 'localZip', location: credentialNativeArchive } }),
    error => error?.rpc?.data?.reason === 'native-client-credentials',
  )

  const unsafePatchArchive = await createPluginArchive({
    archiveName: 'unsafe-patch',
    packageName: '@harness-mobile/unsafe-patch',
    patch: '- insert: !!js process.exit(1)\n',
  })
  await assert.rejects(
    rpc('plugin/install', { source: { kind: 'localZip', location: unsafePatchArchive } }),
    error => error?.rpc?.data?.reason === 'unsafe-patch',
  )

  const symlinkArchive = await createPluginArchive({
    archiveName: 'symlink-probe',
    packageName: '@harness-mobile/symlink-probe',
    symbolicLink: true,
  })
  await assert.rejects(
    rpc('plugin/install', { source: { kind: 'localZip', location: symlinkArchive } }),
    error => error?.rpc?.data?.reason === 'invalid-zip',
  )

  const nativeAddonArchive = await createPluginArchive({
    archiveName: 'native-addon',
    packageName: '@harness-mobile/native-probe',
    nativeAddon: true,
  })
  await assert.rejects(
    rpc('plugin/install', { source: { kind: 'localZip', location: nativeAddonArchive } }),
    error => error?.rpc?.data?.reason === 'native-addon',
  )
  const afterRejectedPackages = await rpc('plugin/list')
  assert.deepEqual(afterRejectedPackages.plugins.map(plugin => plugin.id), [marketPluginID])

  const disabled = await rpc('plugin/set-enabled', { id: marketPluginID, enabled: false })
  assert.equal(disabled.plugin.state, 'disabled')
  const settingsAfterDisable = await rpc('settings/describe')
  assert.ok(!settingsAfterDisable.namespaces.some(entry => entry.ns.startsWith('market-smoke')))
  const contributionsAfterDisable = await rpc('contributions', { sessionId: 'smoke-session' })
  assert.ok(!contributionsAfterDisable.tools.some(tool => tool.name === 'market_smoke_echo'))
  assert.deepEqual(contributionsAfterDisable.nativeClient.plugins, [])
  const uninstalled = await rpc('plugin/uninstall', { id: marketPluginID })
  assert.deepEqual(uninstalled, { ok: true, id: marketPluginID })
  const finalPluginList = await rpc('plugin/list')
  assert.deepEqual(finalPluginList.plugins, [])

  const exitPromise = once(child, 'exit')
  child.stdin.end()
  const [exitCode] = await exitPromise
  assert.equal(exitCode, 0)
  process.stdout.write(`${JSON.stringify({
    host: ping.hostVersion,
    run: run.status,
    invoked: invoked.value,
    marketplace: {
      installedDefault: installed.plugin.state,
      enabledTool: marketInvocation.value,
      rollbackTool: invocationAfterRollback.value,
      nativeEndpoint: nativeEndpointAfterRollback.value.version,
      rejected: [
        'zip-slip',
        'missing-entrypoint',
        'native-unknown-renderer',
        'native-credential',
        'unsafe-patch',
        'symlink',
        'native-addon',
      ],
      finalCount: finalPluginList.plugins.length,
    },
  })}\n`)
} catch (error) {
  if (child.exitCode === null) {
    child.kill()
    await once(child, 'exit')
  }
  throw error
} finally {
  await rm(workspaceRoot, { recursive: true, force: true })
}
