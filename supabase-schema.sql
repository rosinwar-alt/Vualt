-- ============================================================
--  VAULT LEDGER — Supabase schema
--  วิธีใช้: เปิด Supabase Dashboard -> SQL Editor -> New query
--  วางไฟล์นี้ทั้งหมดแล้วกด Run ครั้งเดียว (รันซ้ำได้ ไม่พัง)
-- ============================================================

-- 1) ตาราง "กุญแจ" ของแต่ละผู้ใช้ (เก็บ salt + verifier เท่านั้น
--    ไม่เคยเก็บ master password จริง)
create table if not exists vault_settings (
  user_id     uuid primary key references auth.users(id) on delete cascade,
  salt        text not null,        -- base64, ใช้สุ่มกุญแจเข้ารหัสจาก master password
  verifier    text not null,        -- base64 ciphertext ของข้อความรู้จักไว้ ใช้เช็คว่าใส่ master password ถูก
  verifier_iv text not null,        -- base64 iv ของ verifier
  created_at  timestamptz not null default now()
);

alter table vault_settings enable row level security;

drop policy if exists "own settings only" on vault_settings;
create policy "own settings only" on vault_settings
  for all
  using (auth.uid() = user_id)
  with check (auth.uid() = user_id);

-- 2) ตารางเก็บรายการในวอลต์ (ทุกฟิลด์ที่เป็นข้อมูลจริงถูกเข้ารหัส
--    เป็นก้อนเดียวก่อนถึง database แล้ว ฝั่ง server เห็นแค่ตัวอักษรมั่วๆ)
create table if not exists vault_items (
  id             uuid primary key default gen_random_uuid(),
  user_id        uuid not null references auth.users(id) on delete cascade,
  encrypted_data text not null,   -- base64 ciphertext ของ {platform, username, password, note, category}
  iv             text not null,   -- base64 iv ของรายการนี้
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now()
);

alter table vault_items enable row level security;

drop policy if exists "own items only" on vault_items;
create policy "own items only" on vault_items
  for all
  using (auth.uid() = user_id)
  with check (auth.uid() = user_id);

create index if not exists vault_items_user_idx on vault_items(user_id);

-- 3) ตารางไฟล์แนบ (รูป/เอกสาร) — ไฟล์จริงเก็บใน Storage
--    แถวนี้เก็บแค่ path + iv ที่ใช้ถอดรหัสไฟล์
create table if not exists vault_files (
  id              uuid primary key default gen_random_uuid(),
  user_id         uuid not null references auth.users(id) on delete cascade,
  vault_item_id   uuid not null references vault_items(id) on delete cascade,
  storage_path    text not null,
  encrypted_name  text not null,  -- base64 ciphertext ของชื่อไฟล์เดิม
  name_iv         text not null,
  file_iv         text not null,  -- iv ที่ใช้เข้ารหัสตัวไฟล์
  created_at      timestamptz not null default now()
);

alter table vault_files enable row level security;

drop policy if exists "own files only" on vault_files;
create policy "own files only" on vault_files
  for all
  using (auth.uid() = user_id)
  with check (auth.uid() = user_id);

create index if not exists vault_files_item_idx on vault_items(id);

-- 3.1) เพิ่มคอลัมน์ขนาดไฟล์ (สำหรับหน้าจอ "พื้นที่จัดเก็บ")
--     รันคำสั่งนี้ได้แม้ตาราง vault_files เคยสร้างไว้แล้ว ไม่พัง
alter table vault_files add column if not exists size_bytes bigint;

-- 3.2) ตารางหมวดหมู่ (ให้สร้าง/แก้ไข/ลบหมวดหมู่ได้จากหน้า "จัดการหมวดหมู่"
--     โดยไม่ต้องมีรายการอยู่ในหมวดนั้นก่อน) — ชื่อหมวดหมู่เข้ารหัสเหมือนข้อมูลอื่นๆ
create table if not exists vault_categories (
  id             uuid primary key default gen_random_uuid(),
  user_id        uuid not null references auth.users(id) on delete cascade,
  encrypted_name text not null,   -- base64 ciphertext ของชื่อหมวดหมู่
  name_iv        text not null,   -- base64 iv
  created_at     timestamptz not null default now()
);

alter table vault_categories enable row level security;

drop policy if exists "own categories only" on vault_categories;
create policy "own categories only" on vault_categories
  for all
  using (auth.uid() = user_id)
  with check (auth.uid() = user_id);

create index if not exists vault_categories_user_idx on vault_categories(user_id);

-- 3.3) ไอคอนต่อหมวดหมู่ (เลือกได้จากหน้า "จัดการหมวดหมู่" เช่น controller, crosshair, shield ฯลฯ)
--     เก็บแบบไม่เข้ารหัส เพราะเป็นแค่ชื่อไอคอนทั่วไป ไม่ใช่ข้อมูลส่วนตัว ไม่กระทบความปลอดภัย
alter table vault_categories add column if not exists icon_key text;


-- 4) trigger อัปเดต updated_at อัตโนมัติ
create or replace function set_updated_at()
returns trigger as $$
begin
  new.updated_at = now();
  return new;
end;
$$ language plpgsql;

drop trigger if exists vault_items_set_updated_at on vault_items;
create trigger vault_items_set_updated_at
  before update on vault_items
  for each row execute function set_updated_at();

-- ============================================================
-- 5) Storage bucket สำหรับไฟล์แนบ (รูป/เอกสารที่เข้ารหัสแล้ว)
--    ต้องสร้าง bucket ผ่านหน้า Dashboard -> Storage -> New bucket
--    ตั้งชื่อ: vault-files   และเลือก "Private bucket" (ห้ามติ๊ก public)
--    จากนั้นค่อยมารัน policy ด้านล่างนี้
-- ============================================================

drop policy if exists "vault files own folder select" on storage.objects;
create policy "vault files own folder select" on storage.objects
  for select using (
    bucket_id = 'vault-files'
    and (storage.foldername(name))[1] = auth.uid()::text
  );

drop policy if exists "vault files own folder insert" on storage.objects;
create policy "vault files own folder insert" on storage.objects
  for insert with check (
    bucket_id = 'vault-files'
    and (storage.foldername(name))[1] = auth.uid()::text
  );

drop policy if exists "vault files own folder delete" on storage.objects;
create policy "vault files own folder delete" on storage.objects
  for delete using (
    bucket_id = 'vault-files'
    and (storage.foldername(name))[1] = auth.uid()::text
  );

-- เสร็จแล้ว! ทุกตารางล็อกด้วย RLS ตาม auth.uid() ของผู้ใช้แต่ละคน
-- ไม่มีใครอ่านข้อมูลของอีกคนได้แม้จะใช้ database เดียวกัน
