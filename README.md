# 로또픽 (lottoPick)

D:\lottoPrj\lottoPick 에 이 폴더 내용을 그대로 풀어 놓고 쓰면 됩니다.

```
lottoPick/
├─ sql/lotto_schema.sql          Supabase 테이블 (lotto.draws, lotto.picks)
├─ batch/                        당첨번호 수집·채점·번호추출 (Node.js)
│   ├─ lib.mjs                   동행복권 조회, 채점, 추출 로직
│   ├─ jobs.mjs                  collect / check / generate / weekly
│   ├─ run.mjs                   실행 진입점
│   ├─ .env.example              → .env 로 복사해서 키 입력
│   └─ weekly.bat                Windows 작업 스케줄러용
├─ .github/workflows/lotto-weekly.yml   GitHub 자동 실행 (매주 일 06:10)
├─ flutter/                      기존 Flutter 앱에 넣을 파일
│   ├─ lib/lotto_repository.dart
│   ├─ lib/lotto_home_page.dart
│   ├─ lib/main_example.dart
│   ├─ assets/icon/icon.png, icon_fg.png
│   └─ pubspec_추가할내용.yaml
└─ web/                          stockeye 프로젝트에 넣을 파일
    ├─ public/lotto/index.html, icon.png
    └─ vercel.json.추가할내용.json
```

## 동작 흐름

1. **collect**: DB에 저장된 마지막 회차 다음부터 최신 회차까지 동행복권에서 받아 `lotto.draws`에 저장 (처음 한 번은 1회부터 전부)
2. **check**: 새로 들어온 회차의 `lotto.picks`를 채점 → 맞힌 개수 / 보너스 / 등수 기록
3. **generate**: 다음 회차 번호를 4가지 방식 × 5세트 = 20세트 생성
   - `random` 완전 무작위 / `hot` 최근 100회 자주 나온 번호 가중 / `cold` 오래 안 나온 번호 가중 / `balanced` 홀짝·합계·연속번호 조건 필터
4. **weekly**: 위 1→2→3 을 한 번에 (매주 자동 실행)

로또는 매 회 독립 추첨이므로 어떤 방식도 확률을 높여 주지는 않습니다. `method`별 성적을 쌓아서 비교해 보는 용도입니다.

## 수동 명령 (batch 폴더에서)

```
npm run collect             당첨번호 수집
npm run check -- 1245       1245회 채점
npm run generate            다음 회차 번호 추출
npm run generate -- 1246 --force   다시 추출(추가)
npm run weekly              전체 한 번에
```
