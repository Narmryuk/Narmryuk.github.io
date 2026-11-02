// =============================================================
// TMSI 가위바위보 — Supabase 클라이언트 초기화
// anon key 는 공개 가능한 값(RLS 로 보호). service_role 키는 절대 넣지 않는다.
// CDN ESM 모듈을 사용해 빌드 도구 없이 동작한다.
// =============================================================
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';

const SUPABASE_URL = 'https://odldftdeucupnmtbxenq.supabase.co';
const SUPABASE_ANON_KEY =
  'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Im9kbGRmdGRldWN1cG5tdGJ4ZW5xIiwicm9sZSI6ImFub24iLCJpYXQiOjE3OTM2MDEyNDUsImV4cCI6MjEwOTE3NzI0NX0.klofd7OCxlpZJP4Kq6-2a9-KjY9zuI_r_HtnMdtmtHA';

export const supabase = createClient(SUPABASE_URL, SUPABASE_ANON_KEY, {
  auth: {
    persistSession: true,       // 로그인 상태 유지 (명세 3)
    autoRefreshToken: true,
    detectSessionInUrl: true,
  },
});
