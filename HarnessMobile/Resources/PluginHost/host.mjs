import { readFileSync } from 'node:fs'
import { createRequire } from 'node:module'
import { dirname, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'
import { errorChain } from '@deepseek-ai/dsh-llm'
import {
  loaderBaseURL,
  MarketplaceError,
  MarketplaceManager,
} from './marketplace.mjs'

const HOST_VERSION = '1.8.0'
const PROTOCOL_VERSION = 1
const MAXIMUM_FRAME_BYTES = 512 * 1024
const protocolOutput = process.stdout
const stderrLog = console.error.bind(console)

// Upstream dynamic packages intentionally log through console. Keep stdout as
// a framing-only channel and route every runtime log to the iSH stderr stream.
console.log = stderrLog
console.info = stderrLog
console.warn = stderrLog
console.debug = stderrLog

const forbiddenKeyFragments = [
  'apikey',
  'authorization',
  'accesstoken',
  'refreshtoken',
  'secretkey',
  'clientsecret',
  'password',
]

for (const key of Object.keys(process.env)) {
  const normalized = key.toLowerCase().replace(/[^a-z]/g, '')
  if (forbiddenKeyFragments.some(fragment => normalized.includes(fragment))) {
    delete process.env[key]
  }
}

const workspaceRoot = resolve(process.env.HARNESS_MOBILE_WORKSPACE ?? '/workspace')
process.env.HARNESS_MOBILE_WORKSPACE = workspaceRoot
process.env.DSH_HOME = resolve(workspaceRoot, '.dsh')

const [
  { Context },
  { default: Timer },
  { default: AgentRegistry, Inbox },
  { default: SessionStore },
  { default: CommandRuntime },
  { default: SkillRegistry },
  { SessionQueryEngine },
  { createScope },
  systemPromptModule,
  { default: ToolRuntime },
  { default: DynamicCordisRunnerService },
  ToolCordis,
  { default: Loader },
  { default: Group },
  { default: FileSettingsProvider },
  settingsModule,
] = await Promise.all([
  import('@deepseek-ai/cordis'),
  import('@deepseek-ai/cordis-plugin-timer'),
  import('@deepseek-ai/dsh-agent'),
  import('@deepseek-ai/dsh-session'),
  import('@deepseek-ai/dsh-commands'),
  import('@deepseek-ai/dsh-skill'),
  import('@deepseek-ai/dsh-session-query'),
  import('@deepseek-ai/dsh-scope'),
  import('@deepseek-ai/dsh-system-prompt'),
  import('@deepseek-ai/dsh-tools'),
  import('@deepseek-ai/dsh-cordis-host-runner'),
  import('@deepseek-ai/dsh-tool-cordis'),
  import('@deepseek-ai/cordis-plugin-loader'),
  import('@deepseek-ai/cordis-plugin-group'),
  import('@deepseek-ai/dsh-settings-file'),
  import('@deepseek-ai/dsh-settings'),
])

const { default: SystemPrompt } = systemPromptModule
const { SettingsConflictError, settingsNamespace } = settingsModule
const require = createRequire(import.meta.url)
const hostDirectory = dirname(fileURLToPath(import.meta.url))
const settingsDocumentPath = resolve(workspaceRoot, '.harness-mobile', 'settings.yaml')

class MobileSessionQuery extends SessionQueryEngine {
  async searchSessions() {
    return { items: [] }
  }

  async searchEvents(request) {
    const session = this.ctx.sessions.get(request.sessionId)
    if (session === undefined) {
      throw new Error(`session "${request.sessionId}" not found`)
    }
    return {
      session: structuredClone(session.header),
      items: [],
    }
  }
}

function packageVersion(name) {
  const path = require.resolve(`${name}/package.json`)
  return JSON.parse(readFileSync(path, 'utf8')).version
}

const runtimePackages = Object.freeze({
  '@deepseek-ai/cordis': packageVersion('@deepseek-ai/cordis'),
  '@deepseek-ai/cordis-plugin-loader': packageVersion('@deepseek-ai/cordis-plugin-loader'),
  '@deepseek-ai/dsh-app-boot': packageVersion('@deepseek-ai/dsh-app-boot'),
  '@deepseek-ai/dsh-atomic-write': packageVersion('@deepseek-ai/dsh-atomic-write'),
  '@deepseek-ai/dsh-cordis-host-runner': packageVersion('@deepseek-ai/dsh-cordis-host-runner'),
  '@deepseek-ai/dsh-agent': packageVersion('@deepseek-ai/dsh-agent'),
  '@deepseek-ai/dsh-commands': packageVersion('@deepseek-ai/dsh-commands'),
  '@deepseek-ai/dsh-session': packageVersion('@deepseek-ai/dsh-session'),
  '@deepseek-ai/dsh-session-query': packageVersion('@deepseek-ai/dsh-session-query'),
  '@deepseek-ai/dsh-settings': packageVersion('@deepseek-ai/dsh-settings'),
  '@deepseek-ai/dsh-settings-file': packageVersion('@deepseek-ai/dsh-settings-file'),
  '@deepseek-ai/dsh-skill': packageVersion('@deepseek-ai/dsh-skill'),
  '@deepseek-ai/dsh-system-prompt': packageVersion('@deepseek-ai/dsh-system-prompt'),
  '@deepseek-ai/dsh-tool-cordis': packageVersion('@deepseek-ai/dsh-tool-cordis'),
  '@deepseek-ai/dsh-tools': packageVersion('@deepseek-ai/dsh-tools'),
})

const ctx = new Context()
await ctx.plugin(Timer)
await ctx.plugin(SessionStore)
await ctx.plugin(AgentRegistry)
await ctx.plugin(CommandRuntime)
await ctx.plugin(SkillRegistry)
await ctx.plugin(MobileSessionQuery)
await ctx.plugin(FileSettingsProvider, {
  path: settingsDocumentPath,
  watch: true,
  debounceMs: 100,
})
await ctx.plugin(SystemPrompt, {
  includeHarnessIdentity: false,
  includeRuntimeContext: false,
  persona: '',
})
await ctx.plugin(ToolRuntime, { mode: 'native' })
await ctx.plugin(DynamicCordisRunnerService, { vmTimeoutMs: 5000 })

const runner = ctx.dynamicCordisRunner
const baselineAssembly = await ctx.systemPrompt.assemble()
const baselineSections = new Set(baselineAssembly.sections.map(section => section.name))
const baselineContexts = new Set(baselineAssembly.contexts.map(context => context.name))
const baselineTools = new Set(baselineAssembly.tools.map(tool => tool.name))

await ctx.plugin(ToolCordis)
ctx.systemPrompt.section({
  name: 'mobile:cordis-host-policy',
  order: 116,
  text: `# Mobile Cordis Host Policy

This runtime is the on-device iSH Host for an iPhone app. Dynamic Host-half plugins, Tools, Prompt contributions, Services, Events, and private handlers execute locally in this process.

- There is no browser Client runner. Never submit code.client and never claim that a Client-half package is running.
- Use the official cordis_inspect_list, cordis_inspect_query, cordis_inspect_self, cordis_define, cordis_run, cordis_stop, and cordis_undefine tools for self-modification.
- The desktop cordis-plugin-development Skill is not mounted in this minimal Host. Do not call an absent Skill tool; use Inspect results as the exact capability contract.
- Dynamic definitions and active runs exist only in this Host process memory and disappear when the Host stops or restarts.
- Provider API keys and authorization data are forbidden in this Host. Do not request, embed, log, or forward them.
- A Host llm/stream handler receives credential-free start and per-event envelopes. Return kind "next" or "observe" to release an event, kind "drop" to consume it, or kind "replace" with an event to rewrite it. Terminal finish, error, and cancel envelopes are notifications.
- After a Host-half lifecycle change, its Tool and Prompt contributions become available to the native Agent on the next synchronized model step.`,
})
ctx.tools.guard(execution => {
  if (execution.name === 'cordis_define') {
    const code = execution.arguments?.code
    if (code !== null && typeof code === 'object' && typeof code.client === 'string') {
      return 'The iPhone Host does not have a browser Client runner; define a Host-half package only.'
    }
  }
  if (execution.name === 'cordis_run') {
    try {
      const pluginId = execution.arguments?.pluginId
      const packageId = execution.arguments?.packageId
      if (typeof pluginId === 'string' && typeof packageId === 'string' && execution.agent !== undefined) {
        const inspected = runner.inspectPackage(execution.agent, pluginId, packageId)
        if (inspected.code.client !== undefined) {
          return 'The iPhone Host cannot run Client-half packages without a native Client runner.'
        }
      }
    } catch {
      // Let the official tool return the precise ownership or package error.
    }
  }
  return undefined
})

const agents = new Map()
const skillRegistrations = new Map()
let revision = 0
let nextCallId = 1
const directoryFingerprints = new Map()
const contributionMutationTools = new Set([
  'cordis_define',
  'cordis_run',
  'cordis_stop',
  'cordis_undefine',
])

ctx.on('tools/change', () => { revision += 1 })
ctx.on('commands/change', () => { revision += 1 })
ctx.on('system-prompt/change', () => { revision += 1 })
ctx.on('settings/document-updated', () => { revision += 1 })

class RPCFailure extends Error {
  constructor(code, message, data) {
    super(message)
    this.code = code
    this.data = data
  }
}

await ctx.plugin(Loader, { baseUrl: loaderBaseURL(workspaceRoot) })
ctx.loader.builtins.group = Group
const marketplace = new MarketplaceManager(ctx, {
  workspaceRoot,
  hostDirectory,
  onRevision: () => { revision += 1 },
})
let marketplaceStartupError
try {
  await marketplace.start()
} catch (error) {
  marketplaceStartupError = error
  stderrLog(`[plugin-host] community plugin registry unavailable: ${safeErrorMessage(error)}`)
}

function safeErrorMessage(error) {
  return errorChain(error)
    .replace(/\bsk-[A-Za-z0-9_-]{12,}\b/g, '[credential-shaped text removed]')
    .replace(/\bBearer\s+[A-Za-z0-9._~-]{12,}\b/gi, 'Bearer [removed]')
    .slice(0, 4096)
}

function safeUnhandledDiagnostic(error) {
  const detail = error instanceof Error
    ? `${error.name}: ${error.message}${error.stack === undefined ? '' : `\n${error.stack}`}`
    : String(error)
  return safeErrorMessage(detail)
}

async function marketplaceCall(operation) {
  if (marketplaceStartupError !== undefined) {
    throw new RPCFailure(
      -32010,
      `Community plugin registry is unavailable: ${safeErrorMessage(marketplaceStartupError)}`,
      { reason: 'startup-failed' },
    )
  }
  try {
    return await operation()
  } catch (error) {
    if (error instanceof MarketplaceError) {
      throw new RPCFailure(-32010, safeErrorMessage(error), {
        reason: error.code,
        ...(error.data === undefined ? {} : error.data),
      })
    }
    throw new RPCFailure(-32010, safeErrorMessage(error))
  }
}

function agentFor(sessionId) {
  let agent = agents.get(sessionId)
  if (agent !== undefined) return agent

  const session = ctx.sessions.create(sessionId, {
    meta: { cwd: workspaceRoot },
  })
  agent = {
    id: sessionId,
    options: {},
    session,
    inbox: new Inbox(session, {
      inserted() {},
      discarded() {},
      claimed() {},
    }),
    status: 'idle',
    ctx: undefined,
    cancel() {},
    async whenIdle() {},
    async runMaintenance(task) {
      return await task(new AbortController().signal)
    },
    send() {},
    followup() {},
    steer() {},
    inject() {},
  }
  const scope = createScope(ctx, agent)
  agent.ctx = scope.ctx.extend({ agent })
  ctx.agents.register(agent)
  agents.set(sessionId, agent)
  return agent
}

function appendSyncedEvents(session, startingAtSeq, sourceEvents) {
  if (!Number.isSafeInteger(startingAtSeq) || startingAtSeq < 0) {
    throw new RPCFailure(-32602, 'startingAtSeq must be a non-negative safe integer')
  }
  if (!Array.isArray(sourceEvents)) {
    throw new RPCFailure(-32602, 'events must be an array')
  }
  if (sourceEvents.length > 512) {
    throw new RPCFailure(-32602, 'events exceeds the 512-event synchronization batch limit')
  }

  if (startingAtSeq !== session.events.length) {
    throw new RPCFailure(
      -32020,
      `session "${session.id}" expected synchronization at seq ${session.events.length}, received ${startingAtSeq}`,
      { expectedStartingAtSeq: session.events.length },
    )
  }

  let appended = 0
  for (let offset = 0; offset < sourceEvents.length; offset += 1) {
    const index = startingAtSeq + offset
    const event = sourceEvents[offset]
    if (!isPlainJSONObject(event)
      || event.seq !== index
      || typeof event.type !== 'string'
      || !isPlainJSONObject(event.data)) {
      throw new RPCFailure(-32602, `events[${index}] is not a valid session event`)
    }
    const metadata = {
      ...(event.sourceEventSeqs === undefined ? {} : { sourceEventSeqs: event.sourceEventSeqs }),
      ...(event.surfaceOp === undefined ? {} : { surfaceOp: event.surfaceOp }),
    }
    if (event.surfaceOp === undefined) session.append(event.type, event.data)
    else session.append(event.type, event.data, metadata)
    appended += 1
  }
  return appended
}

function normalizedSkill(raw, index) {
  if (!isPlainJSONObject(raw)) {
    throw new RPCFailure(-32602, `skills[${index}] must be an object`)
  }
  const name = raw.name
  const description = raw.description
  const content = raw.content
  if (typeof name !== 'string' || typeof description !== 'string' || typeof content !== 'string') {
    throw new RPCFailure(-32602, `skills[${index}] requires string name, description, and content`)
  }
  const invocation = isPlainJSONObject(raw.invocation)
    ? raw.invocation
    : { modelInvocable: true, userInvocable: true }
  if (typeof invocation.modelInvocable !== 'boolean' || typeof invocation.userInvocable !== 'boolean') {
    throw new RPCFailure(-32602, `skills[${index}].invocation is invalid`)
  }
  const resourceBase = typeof raw.resourceBase === 'string' && raw.resourceBase.length > 0
    ? { kind: 'directory', path: raw.resourceBase }
    : undefined
  return {
    name,
    description,
    ...(typeof raw.whenToUse === 'string' ? { whenToUse: raw.whenToUse } : {}),
    invocation: {
      modelInvocable: invocation.modelInvocable,
      userInvocable: invocation.userInvocable,
    },
    source: typeof raw.source === 'string' ? raw.source : 'custom',
    provider: 'harness-mobile',
    ...(resourceBase === undefined ? {} : { resourceBase }),
    content,
    ...(typeof raw.path === 'string' ? { path: raw.path } : {}),
  }
}

function synchronizeSkills(sourceSkills) {
  if (!Array.isArray(sourceSkills)) {
    throw new RPCFailure(-32602, 'skills must be an array')
  }
  if (sourceSkills.length > 256) {
    throw new RPCFailure(-32602, 'skills exceeds the 256-skill mobile synchronization limit')
  }
  const next = new Map()
  for (const [index, raw] of sourceSkills.entries()) {
    const skill = normalizedSkill(raw, index)
    if (next.has(skill.name)) {
      throw new RPCFailure(-32602, `duplicate synchronized skill "${skill.name}"`)
    }
    next.set(skill.name, skill)
  }

  for (const [name, registration] of skillRegistrations) {
    const skill = next.get(name)
    const fingerprint = skill === undefined ? undefined : JSON.stringify(skill)
    if (fingerprint === registration.fingerprint) {
      next.delete(name)
      continue
    }
    registration.dispose()
    skillRegistrations.delete(name)
  }
  for (const [name, skill] of next) {
    const fingerprint = JSON.stringify(skill)
    const dispose = ctx.skills.register(skill)
    skillRegistrations.set(name, { fingerprint, dispose })
  }
  return skillRegistrations.size
}

function synchronizeMobileContext(params) {
  const sessionId = requiredString(params, 'sessionId', 128)
  const agent = agentFor(sessionId)
  const appendedEvents = appendSyncedEvents(agent.session, params.startingAtSeq, params.events)
  const skillCount = params.skills === undefined
    ? skillRegistrations.size
    : synchronizeSkills(params.skills)
  return {
    sessionId,
    appendedEvents,
    totalEvents: agent.session.events.length,
    skillCount,
  }
}

function normalizeKey(key) {
  return key.toLowerCase().replace(/[^a-z]/g, '')
}

function containsCredentialPattern(text) {
  return /\bsk-[A-Za-z0-9_-]{12,}\b/.test(text)
    || /\bBearer\s+[A-Za-z0-9._~-]{12,}\b/i.test(text)
}

function assertNoCredentials(value, seen = new Set()) {
  if (typeof value === 'string') {
    if (containsCredentialPattern(value)) {
      throw new RPCFailure(-32001, 'Provider credentials are not allowed in the on-device plugin host.')
    }
    return
  }
  if (value === null || typeof value !== 'object') return
  if (seen.has(value)) return
  seen.add(value)
  if (Array.isArray(value)) {
    for (const item of value) assertNoCredentials(item, seen)
    return
  }
  for (const [key, child] of Object.entries(value)) {
    const normalized = normalizeKey(key)
    if (forbiddenKeyFragments.some(fragment => normalized.includes(fragment))) {
      throw new RPCFailure(-32001, 'Provider credentials are not allowed in the on-device plugin host.')
    }
    assertNoCredentials(child, seen)
  }
}

function assertLosslessJSON(value, path = '$', seen = new Set()) {
  if (value === null || typeof value === 'string' || typeof value === 'boolean') return
  if (typeof value === 'number') {
    if (!Number.isFinite(value)) {
      throw new RPCFailure(-32004, `Plugin result at ${path} contains a non-finite number.`)
    }
    return
  }
  if (typeof value !== 'object') {
    throw new RPCFailure(-32004, `Plugin result at ${path} is not lossless JSON.`)
  }
  if (seen.has(value)) {
    throw new RPCFailure(-32004, `Plugin result at ${path} contains a cycle.`)
  }
  seen.add(value)
  try {
    if (Array.isArray(value)) {
      for (let index = 0; index < value.length; index += 1) {
        if (!Object.hasOwn(value, index)) {
          throw new RPCFailure(-32004, `Plugin result at ${path}[${index}] contains an array hole.`)
        }
        assertLosslessJSON(value[index], `${path}[${index}]`, seen)
      }
      return
    }
    const prototype = Object.getPrototypeOf(value)
    if (prototype !== null) {
      const constructor = Object.getOwnPropertyDescriptor(prototype, 'constructor')?.value
      if (typeof constructor !== 'function' || constructor.name !== 'Object') {
        throw new RPCFailure(-32004, `Plugin result at ${path} is not a plain JSON object.`)
      }
    }
    if (Object.getOwnPropertySymbols(value).length > 0) {
      throw new RPCFailure(-32004, `Plugin result at ${path} contains symbol keys.`)
    }
    for (const key of Object.keys(value)) {
      const descriptor = Object.getOwnPropertyDescriptor(value, key)
      if (descriptor === undefined || !('value' in descriptor)) {
        throw new RPCFailure(-32004, `Plugin result at ${path}.${key} contains an accessor.`)
      }
      assertLosslessJSON(descriptor.value, `${path}.${key}`, seen)
    }
  } finally {
    seen.delete(value)
  }
}

function isPlainJSONObject(value) {
  if (value === null || Array.isArray(value) || typeof value !== 'object') return false
  const prototype = Object.getPrototypeOf(value)
  return prototype === Object.prototype || prototype === null
}

function schemaReference(refs, reference) {
  if (!Number.isSafeInteger(reference) && typeof reference !== 'string') return undefined
  return refs[String(reference)]
}

function credentialLikeFieldName(name) {
  const normalized = normalizeKey(name)
  return forbiddenKeyFragments.some(fragment => normalized.includes(fragment))
}

function valueContainsCredentials(value) {
  try {
    assertNoCredentials(value)
    return false
  } catch (error) {
    if (error instanceof RPCFailure && error.code === -32001) return true
    throw error
  }
}

function settingsPathKey(path) {
  return JSON.stringify(path)
}

function valueHasPath(value, path) {
  let cursor = value
  for (const segment of path) {
    if (!isPlainJSONObject(cursor) || !Object.hasOwn(cursor, segment)) return false
    cursor = cursor[segment]
  }
  return path.length > 0 || value !== undefined
}

function withoutSettingsPaths(value, paths) {
  if (value === undefined) return undefined
  if (paths.some(path => path.length === 0)) return undefined
  const output = structuredClone(value)
  for (const path of paths) {
    let cursor = output
    for (let index = 0; index < path.length - 1; index += 1) {
      const segment = path[index]
      if (!isPlainJSONObject(cursor) || !Object.hasOwn(cursor, segment)) {
        cursor = undefined
        break
      }
      cursor = cursor[segment]
    }
    if (isPlainJSONObject(cursor)) delete cursor[path[path.length - 1]]
  }
  return output
}

function unsupportedSettingsProjection(descriptor, reason) {
  return {
    view: {
      ns: String(descriptor.ns),
      schema: null,
      value: null,
      revision: descriptor.revision,
      applies: descriptor.applies,
      secrets: [],
      editable: false,
      unsupportedReason: reason,
    },
    editable: false,
    secretPaths: [],
  }
}

function projectSettingsDescriptor(descriptor) {
  const envelope = descriptor.schema
  if (!isPlainJSONObject(envelope) || !isPlainJSONObject(envelope.refs)) {
    return unsupportedSettingsProjection(descriptor, 'The serialized schema envelope is invalid.')
  }
  const rootReference = envelope.uid
  const root = schemaReference(envelope.refs, rootReference)
  if (!isPlainJSONObject(root) || root.type !== 'object') {
    return unsupportedSettingsProjection(descriptor, 'Only object settings sections are editable on iPhone.')
  }

  const projectedRefs = {}
  const secretPaths = new Map()
  const activeReferences = new Set()
  let formSupported = true
  let formUnsupportedReason

  const officialSecrets = new Map(
    Array.isArray(descriptor.secrets)
      ? descriptor.secrets
        .filter(secret => isPlainJSONObject(secret) && Array.isArray(secret.path))
        .map(secret => [settingsPathKey(secret.path), secret.set === true])
      : [],
  )

  function recordSecret(path, configured) {
    const key = settingsPathKey(path)
    const official = officialSecrets.get(key)
    const inferred = configured ?? valueHasPath(descriptor.value, path)
    secretPaths.set(key, { path: [...path], set: official ?? inferred })
  }

  function visit(reference, path, containerType = 'object') {
    const referenceKey = String(reference)
    if (activeReferences.has(referenceKey)) {
      throw new Error('Recursive or cyclic settings schemas are not exposed over the mobile wire.')
    }
    const node = schemaReference(envelope.refs, reference)
    if (!isPlainJSONObject(node) || typeof node.type !== 'string') {
      throw new Error('A settings schema reference is missing or malformed.')
    }
    const meta = node.meta === undefined ? {} : node.meta
    if (!isPlainJSONObject(meta)) throw new Error('A settings schema metadata record is malformed.')
    if (meta.role === 'secret' || valueContainsCredentials(meta)) {
      if (containerType !== 'object') {
        throw new Error('Secret fields inside dynamic collections are not wire-safe.')
      }
      recordSecret(path)
      return false
    }

    activeReferences.add(referenceKey)
    try {
      const projected = {
        type: node.type,
        meta: structuredClone(meta),
      }
      switch (node.type) {
        case 'boolean':
        case 'number':
        case 'string':
          break

        case 'const':
          assertLosslessJSON(node.value)
          projected.value = structuredClone(node.value)
          break

        case 'object': {
          if (!isPlainJSONObject(node.dict)) throw new Error('An object schema has no property dictionary.')
          projected.dict = {}
          for (const [key, childReference] of Object.entries(node.dict)) {
            const childPath = [...path, key]
            if (credentialLikeFieldName(key)) {
              recordSecret(childPath)
              continue
            }
            if (visit(childReference, childPath, 'object')) projected.dict[key] = childReference
          }
          break
        }

        case 'union': {
          if (!Array.isArray(node.list) || node.list.length === 0) {
            throw new Error('A union schema has no alternatives.')
          }
          for (const childReference of node.list) {
            const child = schemaReference(envelope.refs, childReference)
            if (!isPlainJSONObject(child) || child.type !== 'const') {
              throw new Error('Only unions made entirely from constants are wire-safe.')
            }
            if (!visit(childReference, path, 'union')) {
              throw new Error('A constant union cannot contain a secret alternative.')
            }
          }
          projected.list = [...node.list]
          break
        }

        case 'array':
        case 'dict': {
          const childReference = node.inner
          if (schemaReference(envelope.refs, childReference) === undefined) {
            throw new Error(`A ${node.type} schema has no element schema.`)
          }
          if (!visit(childReference, path, node.type)) {
            throw new Error('Secret fields inside dynamic collections are not wire-safe.')
          }
          projected.inner = childReference
          if (node.type === 'dict' && node.sKey !== undefined) {
            const keySchema = schemaReference(envelope.refs, node.sKey)
            if (!isPlainJSONObject(keySchema) || keySchema.type !== 'string') {
              throw new Error('A dictionary key schema is not wire-safe.')
            }
            if (!visit(node.sKey, path, 'dict')) {
              throw new Error('A dictionary key schema cannot be secret.')
            }
            projected.sKey = node.sKey
          }
          formSupported = false
          formUnsupportedReason ??= 'Array and dictionary settings are currently read-only on iPhone.'
          break
        }

        default:
          throw new Error(`Schema type "${node.type}" is not wire-safe on iPhone.`)
      }
      projectedRefs[referenceKey] = projected
      return true
    } finally {
      activeReferences.delete(referenceKey)
    }
  }

  try {
    if (!visit(rootReference, [], 'object')) {
      return unsupportedSettingsProjection(descriptor, 'A secret root settings section is not exposed.')
    }
  } catch (error) {
    return unsupportedSettingsProjection(
      descriptor,
      error instanceof Error ? error.message : 'The settings schema is not wire-safe.',
    )
  }

  for (const secret of officialSecrets) {
    if (!secretPaths.has(secret[0])) {
      return unsupportedSettingsProjection(
        descriptor,
        'The settings schema contains a secret path the mobile wire cannot prove safe.',
      )
    }
  }

  const paths = [...secretPaths.values()].map(secret => secret.path)
  const value = withoutSettingsPaths(descriptor.value, paths)
  const base = withoutSettingsPaths(descriptor.base, paths)
  const user = withoutSettingsPaths(descriptor.user, paths)
  const view = {
    ns: String(descriptor.ns),
    schema: { uid: rootReference, refs: projectedRefs },
    value: value ?? null,
    revision: descriptor.revision,
    applies: descriptor.applies,
    secrets: [...secretPaths.values()],
    editable: formSupported,
    ...(formSupported ? {} : { unsupportedReason: formUnsupportedReason }),
    ...(base === undefined ? {} : { base }),
    ...(user === undefined ? {} : { user }),
  }
  assertLosslessJSON(view)
  return { view, editable: formSupported, secretPaths: paths }
}

function settingsSnapshot() {
  const settings = ctx.get('settings')
  if (settings === undefined) {
    throw new RPCFailure(-32011, 'The official Settings provider is not mounted.')
  }
  const descriptors = settings.describe({ redactSecrets: true })
  return {
    settings,
    writable: settings.writable === true,
    hasDocument: typeof settings.documentPath === 'string',
    projections: descriptors.map(projectSettingsDescriptor),
  }
}

function requiredExpectedRevision(object) {
  const value = object.expectedRevision
  if (!Number.isSafeInteger(value) || value < 0) {
    throw new RPCFailure(-32602, 'expectedRevision must be a non-negative safe integer')
  }
  return value
}

function requiredPlainObject(object, key) {
  const value = object[key]
  if (!isPlainJSONObject(value)) {
    throw new RPCFailure(-32602, `${key} must be a JSON object`)
  }
  return value
}

function pathsIntersect(left, right) {
  const common = Math.min(left.length, right.length)
  for (let index = 0; index < common; index += 1) {
    if (left[index] !== right[index]) return false
  }
  return true
}

function patchTouchesSecret(patch, secretPath) {
  let cursor = patch
  for (let index = 0; index < secretPath.length; index += 1) {
    if (!isPlainJSONObject(cursor) || !Object.hasOwn(cursor, secretPath[index])) return false
    cursor = cursor[secretPath[index]]
    if (index < secretPath.length - 1 && !isPlainJSONObject(cursor)) return true
  }
  return true
}

function settingsMutationOps(value) {
  if (!Array.isArray(value) || value.length === 0 || value.length > 256) {
    throw new RPCFailure(-32602, 'ops must contain between 1 and 256 path operations')
  }
  return value.map((raw, index) => {
    if (!isPlainJSONObject(raw) || (raw.op !== 'set' && raw.op !== 'unset')) {
      throw new RPCFailure(-32602, `ops[${index}] must be a set or unset operation`)
    }
    if (!Array.isArray(raw.path) || raw.path.length > 32
      || raw.path.some(segment => typeof segment !== 'string' || segment.length === 0 || segment.length > 128)) {
      throw new RPCFailure(-32602, `ops[${index}].path must be an array of bounded non-empty strings`)
    }
    if (raw.op === 'set' && !Object.hasOwn(raw, 'value')) {
      throw new RPCFailure(-32602, `ops[${index}].value is required for set`)
    }
    if (raw.op === 'unset' && Object.hasOwn(raw, 'value')) {
      throw new RPCFailure(-32602, `ops[${index}] must not carry a value for unset`)
    }
    return raw.op === 'set'
      ? { op: 'set', path: [...raw.path], value: raw.value }
      : { op: 'unset', path: [...raw.path] }
  })
}

function settingsWriteTarget(ns) {
  const snapshot = settingsSnapshot()
  const index = snapshot.projections.findIndex(projection => projection.view.ns === ns)
  if (index < 0) throw new RPCFailure(-32011, `Settings namespace "${ns}" is not registered.`)
  const projection = snapshot.projections[index]
  if (!snapshot.writable) throw new RPCFailure(-32011, 'The Settings provider is read-only.')
  if (!projection.editable) {
    throw new RPCFailure(-32013, `Settings namespace "${ns}" is read-only on iPhone.`, {
      reason: 'unsupported-schema',
    })
  }
  return { settings: snapshot.settings, projection }
}

function settingsWriteFailure(error, ns, expectedRevision) {
  if (error instanceof SettingsConflictError || error?.code === 'SETTINGS_CONFLICT') {
    return new RPCFailure(-32012, `Settings namespace "${ns}" changed after it was read.`, {
      reason: 'settings-conflict',
      ns,
      expectedRevision,
      actualRevision: Number.isSafeInteger(error.actual) ? error.actual : null,
    })
  }
  stderrLog(`[plugin-host] settings write rejected for ${ns}: ${safeErrorMessage(error)}`)
  return new RPCFailure(-32011, `Settings update for "${ns}" was rejected.`, {
    reason: 'settings-rejected',
    ns,
  })
}

async function writeSettings(mode, params) {
  const ns = settingsNamespace(requiredString(params, 'ns', 128))
  const expectedRevision = requiredExpectedRevision(params)
  const { settings, projection } = settingsWriteTarget(String(ns))
  try {
    if (mode === 'mutate') {
      const ops = settingsMutationOps(params.ops)
      if (ops.some(op => projection.secretPaths.some(secret => pathsIntersect(op.path, secret)))) {
        throw new RPCFailure(-32001, 'Secret Settings paths cannot be written through the mobile plugin Host.')
      }
      await settings.mutate(ns, ops, expectedRevision)
    } else if (mode === 'update') {
      const patch = requiredPlainObject(params, 'patch')
      if (projection.secretPaths.some(secret => patchTouchesSecret(patch, secret))) {
        throw new RPCFailure(-32001, 'Secret Settings paths cannot be written through the mobile plugin Host.')
      }
      await settings.update(ns, patch, expectedRevision)
    } else {
      const section = requiredPlainObject(params, 'section')
      if (projection.secretPaths.length > 0) {
        throw new RPCFailure(-32001, 'A redacted Settings namespace cannot be replaced wholesale.')
      }
      await settings.replace(ns, section, expectedRevision)
    }
  } catch (error) {
    if (error instanceof RPCFailure) throw error
    throw settingsWriteFailure(error, String(ns), expectedRevision)
  }
  const updated = settings.describe({ redactSecrets: true })
    .find(descriptor => String(descriptor.ns) === String(ns))
  if (updated === undefined) {
    throw new RPCFailure(-32011, `Settings namespace "${String(ns)}" was disposed after the write.`)
  }
  revision += 1
  return projectSettingsDescriptor(updated).view
}

function paramsObject(value) {
  if (value === undefined) return {}
  if (value === null || Array.isArray(value) || typeof value !== 'object') {
    throw new RPCFailure(-32602, 'params must be a JSON object')
  }
  return value
}

function requiredString(object, key, maximumLength = 1024) {
  const value = object[key]
  if (typeof value !== 'string' || value.length === 0 || value.length > maximumLength) {
    throw new RPCFailure(-32602, `${key} must be a non-empty string of at most ${maximumLength} characters`)
  }
  return value
}

function optionalString(object, key, maximumLength = 1024) {
  const value = object[key]
  if (value === undefined) return undefined
  if (typeof value !== 'string' || value.length > maximumLength) {
    throw new RPCFailure(-32602, `${key} must be a string of at most ${maximumLength} characters`)
  }
  return value
}

function optionalBoolean(object, key, fallback = false) {
  const value = object[key]
  if (value === undefined) return fallback
  if (typeof value !== 'boolean') {
    throw new RPCFailure(-32602, `${key} must be a boolean`)
  }
  return value
}

function definitionSelector(value) {
  const selector = paramsObject(value)
  if (selector.kind === 'new') {
    return { kind: 'new', idPrefix: requiredString(selector, 'idPrefix', 6) }
  }
  if (selector.kind === 'existing') {
    return { kind: 'existing', pluginId: requiredString(selector, 'pluginId', 128) }
  }
  throw new RPCFailure(-32602, 'plugin.kind must be "new" or "existing"')
}

function definitionCode(value) {
  const code = paramsObject(value)
  const host = optionalString(code, 'host', 240 * 1024)
  const client = optionalString(code, 'client', 240 * 1024)
  if (host === undefined && client === undefined) {
    throw new RPCFailure(-32602, 'code.host, code.client, or both are required')
  }
  return {
    ...(host === undefined ? {} : { host }),
    ...(client === undefined ? {} : { client }),
  }
}

function isRootObjectPrototype(value) {
  if (value === null || Object.getPrototypeOf(value) !== null) return false
  return Object.getOwnPropertyDescriptor(value, 'constructor')?.value?.name === 'Object'
}

function isRootFunctionPrototype(value) {
  if (typeof value !== 'function') return false
  const parent = Object.getPrototypeOf(value)
  return isRootObjectPrototype(parent)
    && Object.getOwnPropertyDescriptor(value, 'constructor')?.value?.name === 'Function'
}

function isIntrinsicServicePrototype(value) {
  return value === Object.prototype
    || value === Function.prototype
    || isRootObjectPrototype(value)
    || isRootFunctionPrototype(value)
}

function callableServiceMethods(value) {
  const methods = new Set()
  if (typeof value === 'function') methods.add('call')
  if (value === null || (typeof value !== 'object' && typeof value !== 'function')) return [...methods]
  let cursor = value
  while (cursor !== null && !isIntrinsicServicePrototype(cursor)) {
    for (const name of Object.getOwnPropertyNames(cursor)) {
      if (name === 'constructor' || name.length === 0 || name.length > 128) continue
      const descriptor = Object.getOwnPropertyDescriptor(cursor, name)
      if (descriptor !== undefined && typeof descriptor.value === 'function') methods.add(name)
    }
    cursor = Object.getPrototypeOf(cursor)
  }
  return [...methods].sort()
}

function serviceMethod(value, method) {
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

function activeSnapshots(sessionId) {
  if (sessionId !== undefined) return runner.snapshot(agentFor(sessionId))
  const sessionIds = new Set(runner.inventory().map(entry => entry.agentId))
  return [...sessionIds].flatMap(id => runner.snapshot(agentFor(id)))
}

function activeExtensionDirectory(sessionId) {
  const handlers = []
  const services = []
  for (const plugin of activeSnapshots(sessionId)) {
    const activeRun = plugin.activeRun
    if (activeRun === undefined) continue
    for (const method of activeRun.handlers) {
      handlers.push({
        pluginId: plugin.pluginId,
        pluginRunId: activeRun.pluginRunId,
        method,
      })
    }
    const fiber = activeRun.fiber
    if (fiber === undefined || fiber.state !== 2 || fiber.store === undefined) continue
    for (const [name, implementation] of Object.entries(fiber.store)) {
      if (implementation?.fiber !== fiber) continue
      const methods = callableServiceMethods(implementation.value)
      if (methods.length === 0) continue
      services.push({
        pluginId: plugin.pluginId,
        pluginRunId: activeRun.pluginRunId,
        name,
        methods,
      })
    }
  }
  handlers.sort((left, right) => (
    left.pluginId.localeCompare(right.pluginId)
      || left.pluginRunId.localeCompare(right.pluginRunId)
      || left.method.localeCompare(right.method)
  ))
  services.sort((left, right) => (
    left.pluginId.localeCompare(right.pluginId)
      || left.pluginRunId.localeCompare(right.pluginRunId)
      || left.name.localeCompare(right.name)
  ))
  return { handlers, services }
}

function trackExtensionDirectory(sessionId, directory) {
  const key = sessionId ?? '*'
  const fingerprint = JSON.stringify(directory)
  const previous = directoryFingerprints.get(key)
  if (previous === undefined) {
    directoryFingerprints.set(key, fingerprint)
    if (directory.handlers.length > 0 || directory.services.length > 0) revision += 1
    return
  }
  if (previous !== fingerprint) {
    directoryFingerprints.set(key, fingerprint)
    revision += 1
  }
}

function exactActiveRun(sessionId, pluginId, pluginRunId) {
  const plugin = runner.snapshot(agentFor(sessionId)).find(entry => entry.pluginId === pluginId)
  if (plugin?.activeRun === undefined) {
    return {
      ok: false,
      code: 'plugin-not-running',
      message: `dynamic plugin "${pluginId}" is not running in session "${sessionId}"`,
    }
  }
  if (plugin.activeRun.pluginRunId !== pluginRunId) {
    return {
      ok: false,
      code: 'stale-run',
      message: `activation "${pluginRunId}" is no longer active`,
    }
  }
  return { ok: true, activeRun: plugin.activeRun }
}

async function invokeService(sessionId, pluginId, pluginRunId, name, method, args) {
  const exact = exactActiveRun(sessionId, pluginId, pluginRunId)
  if (!exact.ok) return exact
  const fiber = exact.activeRun.fiber
  if (fiber === undefined || fiber.state !== 2 || fiber.store === undefined) {
    return {
      ok: false,
      code: 'service-not-active',
      message: `dynamic plugin "${pluginId}" has no active Host service context`,
    }
  }
  const implementation = fiber.store[name]
  if (implementation === undefined || implementation.fiber !== fiber) {
    return {
      ok: false,
      code: 'service-not-found',
      message: `dynamic plugin "${pluginId}" provides no Host service "${name}"`,
    }
  }
  const callable = serviceMethod(implementation.value, method)
  if (callable === undefined) {
    return {
      ok: false,
      code: 'method-not-found',
      message: `Host service "${name}" exposes no callable method "${method}"`,
    }
  }
  try {
    const value = await callable.call(implementation.value, args)
    assertLosslessJSON(value)
    return { ok: true, value }
  } catch (error) {
    return {
      ok: false,
      code: error instanceof RPCFailure && error.code === -32004 ? 'non-json-result' : 'service-error',
      message: error instanceof Error ? error.message : String(error),
    }
  }
}

async function contributions(sessionId) {
  const agent = sessionId === undefined ? undefined : agentFor(sessionId)
  const assembly = await ctx.systemPrompt.assemble(
    agent === undefined ? {} : { agent, scope: agent },
  )
  const variables = {}
  for (const [name, value] of Object.entries(assembly.variables)) {
    variables[name] = value === undefined ? null : value
  }
  const directory = activeExtensionDirectory(sessionId)
  trackExtensionDirectory(sessionId, directory)
  const commands = agent === undefined ? [] : ctx.commands.list(agent).map(descriptor => {
    const definition = ctx.commands.find(agent, descriptor.name)
    return {
      ...descriptor,
      recordInput: definition?.recordInput !== false,
    }
  })
  return {
    revision,
    scope: sessionId === undefined ? 'process' : 'session',
    tools: assembly.tools.filter(tool => !baselineTools.has(tool.name)),
    commands,
    prompt: {
      sections: assembly.sections.filter(section => !baselineSections.has(section.name)),
      contexts: assembly.contexts.filter(context => !baselineContexts.has(context.name)),
      variables,
    },
    handlers: directory.handlers,
    services: directory.services,
    nativeClient: {
      revision,
      ...marketplace.nativeClientDirectory(),
    },
  }
}

function normalizedCommandResult(name, value) {
  if (value === null || typeof value !== 'object' || Array.isArray(value)) {
    throw new RPCFailure(-32004, `command "${name}" returned a non-object result`)
  }
  if (value.kind !== 'success' && value.kind !== 'error') {
    throw new RPCFailure(-32004, `command "${name}" returned unknown result kind`)
  }
  if (value.text !== undefined && typeof value.text !== 'string') {
    throw new RPCFailure(-32004, `command "${name}" returned a non-string text`)
  }
  if (value.sourceEventSeq !== undefined
      && (!Number.isSafeInteger(value.sourceEventSeq) || value.sourceEventSeq < 0)) {
    throw new RPCFailure(-32004, `command "${name}" returned an invalid sourceEventSeq`)
  }
  return {
    kind: value.kind,
    ...(value.text === undefined ? {} : { text: value.text }),
    ...(value.kind === 'success' && value.sourceEventSeq !== undefined
      ? { sourceEventSeq: value.sourceEventSeq }
      : {}),
  }
}

async function executeCommand(params) {
  const sessionId = requiredString(params, 'sessionId', 128)
  const name = requiredString(params, 'name', 128)
  const commandId = requiredString(params, 'commandId', 128)
  const rawInput = optionalString(params, 'rawInput', 32 * 1024) ?? ''
  const agent = agentFor(sessionId)
  const definition = ctx.commands.find(agent, name)
  if (definition === undefined) {
    return { ok: false, code: 'command-not-found', message: `command "/${name}" is no longer active` }
  }

  try {
    // Native owns the durable command/run + command/done pair. Calling the
    // official handler directly avoids appending a second, Host-only pair to
    // the mirrored SessionStore while preserving the official definition and
    // scoped command resolution semantics.
    const value = await definition.handler(Object.freeze({
      commandId,
      agent,
      rawInput,
      attachments: Object.freeze([]),
      signal: new AbortController().signal,
    }))
    return { ok: true, value: normalizedCommandResult(name, value) }
  } catch (error) {
    return {
      ok: false,
      code: error instanceof RPCFailure ? 'invalid-command-result' : 'command-error',
      message: error instanceof Error ? error.message : String(error),
    }
  }
}

async function dispatch(method, rawParams) {
  const params = paramsObject(rawParams)
  switch (method) {
    case 'ping':
      return {
        protocolVersion: PROTOCOL_VERSION,
        hostVersion: HOST_VERSION,
        runtime: 'iSH/Node/Cordis',
        dynamicDefinitionLifetime: 'process-memory-only',
        credentialBoundary: 'provider credentials are rejected before dispatch',
        packages: runtimePackages,
        capabilities: [
          'ping',
          'inventory',
          'define',
          'run',
          'stop',
          'undefine',
          'context/sync',
          'contributions',
          'command/execute',
          'invoke',
          'settings/describe',
          'settings/mutate',
          'settings/update',
          'settings/replace',
          'market/catalog',
          'plugin/list',
          'plugin/prepare-native',
          'plugin/discard-prepared-native',
          'plugin/install',
          'plugin/set-enabled',
          'plugin/uninstall',
          'plugin/cache-clear',
        ],
      }
    case 'inventory': {
      const sessionId = optionalString(params, 'sessionId', 128)
      const entries = runner.inventory().filter(entry => sessionId === undefined || entry.agentId === sessionId)
      return { revision, entries, packages: runtimePackages }
    }
    case 'define': {
      const sessionId = requiredString(params, 'sessionId', 128)
      const result = runner.define({
        sessionId,
        plugin: definitionSelector(params.plugin),
        name: requiredString(params, 'name', 128),
        purpose: requiredString(params, 'purpose', 2048),
        code: definitionCode(params.code),
      })
      revision += 1
      return result
    }
    case 'run': {
      const sessionId = requiredString(params, 'sessionId', 128)
      const pluginId = requiredString(params, 'pluginId', 128)
      const packageId = requiredString(params, 'packageId', 128)
      const mode = requiredString(params, 'mode', 16)
      if (mode !== 'run' && mode !== 'update') {
        throw new RPCFailure(-32602, 'mode must be "run" or "update"')
      }
      const agent = agentFor(sessionId)
      const inspected = runner.inspectPackage(agent, pluginId, packageId)
      if (inspected.code.client !== undefined) {
        throw new RPCFailure(
          -32002,
          'Client-half packages require a native mobile client runner and are not executed by the iSH Host.',
        )
      }
      const result = await runner.run(agent, pluginId, packageId, mode)
      if (result.ok) revision += 1
      return result
    }
    case 'stop': {
      const agent = agentFor(requiredString(params, 'sessionId', 128))
      const result = await runner.stop(agent, requiredString(params, 'pluginId', 128))
      if (result.ok) revision += 1
      return result
    }
    case 'undefine': {
      const agent = agentFor(requiredString(params, 'sessionId', 128))
      const result = await runner.undefine(agent, requiredString(params, 'pluginId', 128))
      if (result.ok) revision += 1
      return result
    }
    case 'context/sync':
      return synchronizeMobileContext(params)
    case 'contributions': {
      const sessionId = optionalString(params, 'sessionId', 128)
      return await contributions(sessionId)
    }
    case 'command/execute':
      return await executeCommand(params)
    case 'settings/describe': {
      const snapshot = settingsSnapshot()
      return {
        writable: snapshot.writable,
        hasDocument: snapshot.hasDocument,
        namespaces: snapshot.projections.map(projection => projection.view),
      }
    }
    case 'settings/mutate':
      return await writeSettings('mutate', params)
    case 'settings/update':
      return await writeSettings('update', params)
    case 'settings/replace':
      return await writeSettings('replace', params)
    case 'market/catalog':
      return await marketplaceCall(() => marketplace.catalog({
        forceRefresh: optionalBoolean(params, 'forceRefresh'),
      }))
    case 'plugin/list':
      return await marketplaceCall(() => marketplace.list())
    case 'plugin/prepare-native':
      return await marketplaceCall(() => marketplace.prepareNative(params))
    case 'plugin/discard-prepared-native':
      return await marketplaceCall(() => marketplace.discardPreparedNative(
        requiredString(params, 'preparedToken', 64),
      ))
    case 'plugin/install':
      return await marketplaceCall(() => marketplace.install(params))
    case 'plugin/set-enabled':
      return await marketplaceCall(() => marketplace.setEnabled(
        requiredString(params, 'id', 128),
        optionalBoolean(params, 'enabled'),
      ))
    case 'plugin/uninstall':
      return await marketplaceCall(() => marketplace.uninstall(requiredString(params, 'id', 128)))
    case 'plugin/cache-clear':
      return await marketplaceCall(() => marketplace.clearCache({
        includeNpm: optionalBoolean(params, 'includeNpm'),
      }))
    case 'invoke': {
      const target = requiredString(params, 'target', 32)
      const args = params.arguments ?? null
      if (target === 'tool') {
        const agent = agentFor(requiredString(params, 'sessionId', 128))
        const name = requiredString(params, 'name', 128)
        const callId = optionalString(params, 'callId', 128) ?? `mobile-${nextCallId++}`
        const result = await ctx.agents.withInitiator(agent, () => ctx.tools.execute({
          signal: new AbortController().signal,
          callId,
          name,
          arguments: args,
          agent,
        }))
        if (contributionMutationTools.has(name) && result?.isError !== true) revision += 1
        return result
      }
      if (target === 'handler') {
        const sessionId = requiredString(params, 'sessionId', 128)
        const pluginId = requiredString(params, 'pluginId', 128)
        const pluginRunId = requiredString(params, 'pluginRunId', 128)
        const exact = exactActiveRun(sessionId, pluginId, pluginRunId)
        if (!exact.ok) return exact
        const result = await runner.invoke(
          pluginId,
          pluginRunId,
          requiredString(params, 'method', 128),
          args,
        )
        if (result.ok) assertLosslessJSON(result.value)
        return result
      }
      if (target === 'service') {
        return await invokeService(
          requiredString(params, 'sessionId', 128),
          requiredString(params, 'pluginId', 128),
          requiredString(params, 'pluginRunId', 128),
          requiredString(params, 'service', 128),
          requiredString(params, 'method', 128),
          args,
        )
      }
      if (target === 'nativeClientEndpoint') {
        const activationGeneration = params.activationGeneration
        if (!Number.isSafeInteger(activationGeneration) || activationGeneration < 1) {
          throw new RPCFailure(-32602, 'activationGeneration must be a positive safe integer')
        }
        const result = await marketplaceCall(() => marketplace.invokeNativeClientEndpoint({
          pluginId: requiredString(params, 'pluginId', 128),
          activationGeneration,
          endpointId: requiredString(params, 'endpointId', 128),
          arguments: args,
        }))
        assertLosslessJSON(result)
        return result
      }
      throw new RPCFailure(-32602, 'target must be "tool", "handler", "service", or "nativeClientEndpoint"')
    }
    default:
      throw new RPCFailure(-32601, `Unknown method: ${method}`)
  }
}

function writeResponse(response) {
  assertNoCredentials(response)
  protocolOutput.write(`${JSON.stringify(response)}\n`)
}

function errorResponse(id, error) {
  const rpcError = error instanceof RPCFailure
    ? error
    : new RPCFailure(-32000, error instanceof Error ? error.message : String(error))
  return {
    jsonrpc: '2.0',
    id,
    error: {
      code: rpcError.code,
      message: rpcError.message,
      ...(rpcError.data === undefined ? {} : { data: rpcError.data }),
    },
  }
}

async function handleLine(line) {
  let request
  try {
    request = JSON.parse(line)
  } catch {
    writeResponse(errorResponse(null, new RPCFailure(-32700, 'Invalid JSON')))
    return
  }

  const id = request !== null && (typeof request.id === 'string' || typeof request.id === 'number')
    ? request.id
    : null
  let trackedRequest = false
  try {
    if (request === null || Array.isArray(request) || typeof request !== 'object'
      || request.jsonrpc !== '2.0' || id === null || typeof request.method !== 'string') {
      throw new RPCFailure(-32600, 'Invalid JSON-RPC request')
    }
    activeRequests.set(String(id), request.method)
    trackedRequest = true
    assertNoCredentials(request.params)
    const result = await dispatch(request.method, request.params)
    assertNoCredentials(result)
    writeResponse({ jsonrpc: '2.0', id, result })
  } catch (error) {
    writeResponse(errorResponse(id, error))
  } finally {
    if (trackedRequest) activeRequests.delete(String(id))
  }
}

let input = Buffer.alloc(0)
const inFlight = new Set()
const activeRequests = new Map()

function trackInFlight(operation) {
  inFlight.add(operation)
  void operation.then(
    () => { inFlight.delete(operation) },
    error => {
      inFlight.delete(operation)
      stderrLog(`[plugin-host] request escaped its RPC boundary: ${safeUnhandledDiagnostic(error)}`)
    },
  )
}

process.stdin.on('data', (chunk) => {
  input = Buffer.concat([input, chunk])
  while (true) {
    const newline = input.indexOf(0x0A)
    if (newline < 0) break
    let line = input.subarray(0, newline)
    input = input.subarray(newline + 1)
    if (line.length > 0 && line[line.length - 1] === 0x0D) line = line.subarray(0, line.length - 1)
    if (line.length === 0) continue
    if (line.length > MAXIMUM_FRAME_BYTES) {
      writeResponse(errorResponse(null, new RPCFailure(-32600, 'JSON-RPC frame is too large')))
      continue
    }
    const operation = handleLine(line.toString('utf8'))
    trackInFlight(operation)
  }
  if (input.length > MAXIMUM_FRAME_BYTES) {
    writeResponse(errorResponse(null, new RPCFailure(-32600, 'JSON-RPC frame is too large')))
    process.stdin.destroy()
  }
})

process.stdin.on('end', async () => {
  if (input.length > 0 && input.length <= MAXIMUM_FRAME_BYTES) {
    const operation = handleLine(input.toString('utf8'))
    trackInFlight(operation)
  }
  await Promise.allSettled([...inFlight])
  // The file-backed Settings provider owns a live chokidar handle. Stdin EOF
  // is the transport's shutdown boundary, so exit only after every accepted
  // request has settled instead of leaving the watcher to keep Node alive.
  process.exit(0)
})

process.on('uncaughtException', error => {
  stderrLog(`[plugin-host] uncaught exception; terminating the isolated Host process: ${safeUnhandledDiagnostic(error)}`)
  process.exitCode = 70
})

process.on('unhandledRejection', error => {
  const active = [...activeRequests.entries()]
    .map(([id, method]) => `${method}#${id}`)
    .join(', ')
  // Request-scoped marketplace failures are already converted to JSON-RPC
  // errors. A late transport rejection must not terminate the shared Host
  // and make an unrelated ping or diagnostic request time out. Keep the
  // redacted detail in stderr/diagnostics and let the next request proceed.
  stderrLog(`[plugin-host] unhandled rejection; keeping the isolated Host alive${active === '' ? '' : `; active=${active}`}: ${safeUnhandledDiagnostic(error)}`)
})
