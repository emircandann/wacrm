import { readFileSync } from 'fs'
import { join, dirname } from 'path'
import { fileURLToPath } from 'url'

const __dirname = dirname(fileURLToPath(import.meta.url))
const root = join(__dirname, '..')

// Load .env.local
const env = readFileSync(join(root, '.env.local'), 'utf8')
for (const line of env.split('\n')) {
  const t = line.trim()
  if (!t || t.startsWith('#')) continue
  const eq = t.indexOf('=')
  if (eq === -1) continue
  const k = t.slice(0, eq).trim()
  const v = t.slice(eq + 1).trim()
  if (!process.env[k]) process.env[k] = v
}

import bcrypt from 'bcryptjs'
import postgres from 'postgres'

const EMAIL = 'admin@wacrm.local'
const PASSWORD = 'Admin1234!'

const sql = postgres(process.env.DATABASE_URL, { max: 1 })

const hash = await bcrypt.hash(PASSWORD, 12)

const rows = await sql`
  INSERT INTO users (email, password_hash)
  VALUES (${EMAIL}, ${hash})
  ON CONFLICT (email) DO UPDATE SET password_hash = EXCLUDED.password_hash
  RETURNING id, email
`

console.log('Kullanıcı oluşturuldu:')
console.log('  Email   :', rows[0].email)
console.log('  Şifre   :', PASSWORD)
console.log('  User ID :', rows[0].id)

await sql.end()
