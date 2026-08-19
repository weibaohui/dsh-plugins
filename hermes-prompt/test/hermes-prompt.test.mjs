import { test } from 'node:test'
import assert from 'node:assert/strict'
import plugin from '../src/index.js'

test('plugin mounts the Hermes discipline section at order 50', () => {
  assert.equal(plugin.name, 'hermes-prompt')
  assert.deepEqual(plugin.inject, ['systemPrompt'])
  const sections = []
  const ctx = {
    systemPrompt: { section: s => sections.push(s) },
    logger: { info: () => {} },
  }
  plugin.apply(ctx, {})
  assert.equal(sections.length, 1)
  assert.equal(sections[0].name, 'hermes:discipline')
  assert.equal(sections[0].order, 50)
  assert.ok(sections[0].text.includes('Hermes Prompt Framework'))
  assert.ok(sections[0].text.includes('交付纪律'))
})
