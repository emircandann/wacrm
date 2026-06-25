/**
 * Local database setup script.
 * Runs: drizzle-kit push (tables) → setup-functions.sql (functions + triggers)
 *
 * Usage: node scripts/setup-db.mjs
 */

import { readFileSync } from 'fs'
import { join, dirname } from 'path'
import { fileURLToPath } from 'url'
import { execSync } from 'child_process'

const __dirname = dirname(fileURLToPath(import.meta.url))
const root = join(__dirname, '..')

// Load .env.local manually (Next.js doesn't auto-load it in plain Node)
function loadEnv() {
  try {
    const env = readFileSync(join(root, '.env.local'), 'utf8')
    for (const line of env.split('\n')) {
      const trimmed = line.trim()
      if (!trimmed || trimmed.startsWith('#')) continue
      const eq = trimmed.indexOf('=')
      if (eq === -1) continue
      const key = trimmed.slice(0, eq).trim()
      const val = trimmed.slice(eq + 1).trim()
      if (!process.env[key]) process.env[key] = val
    }
  } catch {
    console.error('Could not read .env.local')
    process.exit(1)
  }
}

loadEnv()

const DATABASE_URL = process.env.DATABASE_URL
if (!DATABASE_URL) {
  console.error('DATABASE_URL is not set in .env.local')
  process.exit(1)
}

console.log('DATABASE_URL:', DATABASE_URL.replace(/:([^:@]+)@/, ':***@'))

// Step 1: push schema with drizzle-kit
console.log('\n--- Step 1: drizzle-kit push (create/update tables) ---')
try {
  execSync('npx drizzle-kit push --force', {
    cwd: root,
    stdio: 'inherit',
    env: { ...process.env },
  })
} catch (err) {
  console.error('drizzle-kit push failed:', err.message)
  process.exit(1)
}

// Step 2: run functions + triggers SQL
console.log('\n--- Step 2: setup-functions.sql (functions + triggers) ---')

const { default: postgres } = await import('postgres')
const sql = postgres(DATABASE_URL, { max: 1 })

try {
  const sqlText = readFileSync(join(__dirname, 'setup-functions.sql'), 'utf8')
  await sql.unsafe(sqlText)
  console.log('Functions and triggers created successfully.')
} catch (err) {
  console.error('SQL setup failed:', err.message)
  await sql.end()
  process.exit(1)
}

await sql.end()
console.log('\nDatabase setup complete. Run: npm run dev')
