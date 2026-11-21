# 대륜E&S 교육 QR 출석 인증 (웹 버전)

- 구성: **Supabase**(DB·관리자 로그인, 무료 플랜 가능) + **Vercel**(정적 웹 배포, 무료)
- 직원: 회원가입·로그인 없음 → QR 스캔 → 팀·이름 선택 → 인증
- 관리자(인사팀): 이메일 로그인 → 명단 등록, 회차 생성, QR 띄우기, 결과 CSV 취합

## 파일 구성

| 파일 | 역할 |
|---|---|
| `index.html` | 관리자 화면 (로그인, 교육 회차, 직원 명단, QR 화면, 출석부 인쇄) |
| `c.html` | 직원 휴대폰 인증 화면 (QR 스캔하면 열림) |
| `config.js` | Supabase 주소·키 설정 (**이 파일만 수정**) |
| `style.css` | 공통 디자인 |
| `supabase/schema.sql` | DB 테이블·권한·인증 함수 (Supabase에 1회 실행) |

---

## 1단계. Supabase 프로젝트 만들기 (약 5분)

1. supabase.com 가입 → **New project**
   - Region: **Northeast Asia (Seoul)** 선택
   - DB 비밀번호는 따로 보관
2. 왼쪽 **SQL Editor** → **+ New query**
   - zip을 푼 폴더의 `supabase/schema.sql` 파일을 메모장(또는 VS Code)으로 열기
   - **파일 안의 내용 전체**(Ctrl+A → Ctrl+C)를 복사해 편집창에 붙여넣기 → **Run**
     (파일 이름 `supabase/schema.sql`을 입력하는 게 아님)
   - "destructive operation(파괴적 작업)" 경고창이 뜨면 **Run this query** 클릭
     (기존 권한 규칙을 지우고 다시 만드는 `drop policy` 때문이며 데이터는 지워지지 않음)
   - 아래 결과창에 "Success. No rows returned" 확인. 다시 실행해도 데이터는 유지됨

## 2단계. config.js 설정

1. Supabase **Project Settings → API** 이동
2. `Project URL` → `SUPABASE_URL`에 붙여넣기
3. `anon public` 키 → `SUPABASE_ANON_KEY`에 붙여넣기
   - ⚠ `service_role` 키는 절대 넣지 말 것 (전체 권한 키)

## 3단계. 관리자 계정 만들기

1. **Authentication → Users → Add user → Create new user**
   - 인사팀 이메일·비밀번호 입력, "Auto Confirm User" 체크
2. **SQL Editor**에서 관리자 등록 (이메일만 바꿔 실행)
   ```sql
   insert into public.admins(email) values ('hr@회사도메인') on conflict do nothing;
   ```
3. 외부인 가입 차단: **Authentication → Sign In / Providers → Allow new users to sign up 끄기**
   - admins 목록에 없는 계정은 로그인해도 아무 데이터도 못 봄 (이중 안전장치)

## 4단계. Vercel 배포

- 방법 A (GitHub 사용)
  1. 이 폴더를 GitHub 저장소(비공개 가능)에 올림
  2. vercel.com → **Add New → Project → 저장소 Import**
  3. Framework Preset: **Other**, 설정 변경 없이 **Deploy**
  4. 발급 주소 예: `https://daeryun-edu.vercel.app`
- 방법 B (CLI)
  ```bash
  npm i -g vercel
  cd qr-attendance-web
  vercel --prod
  ```
- 관리자 화면: `https://배포주소/` / 직원 화면은 QR이 자동으로 `c.html`로 연결

---

## v2 업데이트 (이미 설치해서 쓰고 있는 경우)

1. Supabase **SQL Editor** → `supabase/update_v2.sql` 파일 내용 전체 붙여넣기 → **Run** (데이터 유지)
2. Vercel 프로젝트에 새 `index.html`, `c.html`, `style.css` 반영 (아래 "파일 다시 올리기")
3. 바뀐 점
   - 직원 인증 시 **사내번호 직접 입력** → 명단과 숫자 대조 (명단에 사내번호가 빈 직원은 대조 생략)
   - 회차 만들기에 **대상자 사번 지정** 칸 → 대상 아닌 사람이 인증하면 비고에 파란색 **'차수변경'**
   - 이 회차 대상인데 같은 과정의 다른 회차를 들은 사람 → 결과 '타회차', 비고 '차수변경(○회차 수강)'
   - 출석부·CSV 연번: **팀 → 이름 가나다순** (불참자 포함 전체 정렬)

### 파일 다시 올리기 (Vercel)
- `config.js`는 그대로 두고, 나머지 파일만 새 파일로 바꾼 폴더를 준비
- 기존 프로젝트를 지우지 않고 올리려면: Vercel CLI `vercel --prod` (폴더 안에서 실행)
- CLI가 어렵다면: Vercel 새 프로젝트로 폴더 업로드 → 새 고정 주소 사용 (이전 프로젝트 삭제)

## 교육 당일 사용 순서

1. 관리자 화면 → **직원 명단** → 엑셀에서 `팀이름 | 이름 | 사번 | 사내번호` 4개 열 복사·붙여넣기
2. **교육 회차** → **+ 새 회차 만들기** (일시, 장소, 이수 기준 분, 대상 팀)
3. 교육 시작 전 **▶ 입실 인증 시작** → **QR 화면 열기(새 창)** → 빔프로젝터에 띄움
4. 직원: 휴대폰 카메라로 QR 스캔 → 팀·이름 선택 → **입실 인증하기**
5. 교육 종료 시 **▶ 퇴실 인증 시작** → 같은 방식으로 퇴실 인증
6. **■ 인증 마감** → 결과 확인
   - 이수 / 확인필요 / 미이수 자동 판정, 담당자가 판정 변경 가능
   - 미인증 대상자 목록, 관리자 수동 등록(휴대폰 미지참 등)
7. 취합
   - 회차별: **엑셀(CSV) 다운로드**, **출석부 인쇄**(A4, PDF 저장 가능)
   - 전체: 회차 목록의 **전체 출석 기록 CSV** (모든 회차·직원 1행씩)

## 판정 기준

| 결과 | 조건 |
|---|---|
| 이수 | 입실·퇴실 모두 인증 + 체류시간 ≥ 이수 기준(분) |
| 미이수 | 체류시간 < 이수 기준 |
| 확인필요 | 입실 또는 퇴실 누락 / 같은 휴대폰으로 2명 이상 인증 |
| 불참 | 대상자인데 인증 기록 없음 (출석부·CSV에 표시) |

## 보안·대리 인증 방지 장치

- QR은 30초마다 바뀌는 서명값 → **5분 지난 QR 사진으로는 인증 불가** (서버에서 검증)
- 직원 화면은 DB에 직접 접근 불가, 인증 함수 2개(`checkin_context`, `checkin_submit`)만 호출
- 명단(이름·사내번호)은 **유효한 QR을 스캔한 사람에게만** 내려감
- 같은 휴대폰으로 여러 명 인증 시 자동 **확인필요** 표시
- 회차 설정 **"본인 확인 강화"** 체크 시: 화면에 사번을 숨기고 직원이 사번을 직접 입력해야 인증
- 관리 화면은 admins 테이블에 등록된 이메일만 사용 가능

## 참고

- 비용: 직원 수백 명·연 수십 회차 규모는 Supabase/Vercel 무료 플랜 범위
- Supabase 무료 프로젝트는 **7일간 접속이 없으면 일시정지** → 대시보드에서 Restore(1분), 교육 전날 한 번 접속 권장
- 개인정보 보관기간(3년) 경과 기록은 SQL Editor에서 삭제
  ```sql
  delete from public.sessions where edu_date < current_date - interval '3 years';
  ```
  (회차 삭제 시 해당 출석 기록도 함께 삭제)
