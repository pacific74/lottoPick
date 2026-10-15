// 사용법:
//   node run.mjs collect              당첨번호 수집 (처음엔 1회부터 전부)
//   node run.mjs check 1245           1245회 추출번호 채점
//   node run.mjs generate             다음 회차 번호 추출
//   node run.mjs generate 1246 --force  1246회 번호를 강제로 다시 추출(추가)
//   node run.mjs weekly               수집 → 채점 → 추출 한 번에
import { collect, check, generate, weekly } from './jobs.mjs';

const [cmd, arg, flag] = process.argv.slice(2);
const round = arg && /^\d+$/.test(arg) ? Number(arg) : undefined;

try {
  switch (cmd) {
    case 'collect': await collect(); break;
    case 'check':
      if (!round) throw new Error('회차를 입력하세요. 예) node run.mjs check 1245');
      await check(round); break;
    case 'generate': await generate(round, { force: flag === '--force' || arg === '--force' }); break;
    case 'weekly': await weekly(); break;
    default:
      console.log('명령: collect | check <회차> | generate [회차] [--force] | weekly');
      process.exit(1);
  }
  console.log('완료');
} catch (e) {
  console.error('오류:', e.message ?? e);
  process.exit(1);
}
