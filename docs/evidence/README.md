# 실행 기록 (docs/evidence)

스크립트가 실행할 때마다 자동으로 남기는 기록입니다. 실제 AWS 계정에서 실행한 결과만 이 폴더에 둡니다.

| 파일 | 만드는 스크립트 | 용도 |
| --- | --- | --- |
| `verify-<시각>.txt` | `scripts/verify.sh` | 라우팅·SG·/health·SSH 검증 (체크리스트 1-1, 1-3, 1-4) |
| `iam-check-<시각>.txt` | `scripts/iam-check.sh` | 최소 권한 허용·거부 경계 (3-2, 4-2) |
| `troubleshoot-<사례>-<시각>.txt` | `scripts/troubleshoot.sh` | 트러블슈팅 보고서 "실제 관측" |
| `audit-<시각>.txt` | `scripts/audit.sh` (cleanup.sh 마지막에도 실행) | 정리 완료 근거 (1-5) |

공개 저장소라면 올리기 전에 계정 ID·IP 가 드러나도 괜찮은지 확인하세요 (필요하면 일부를 `x` 로 가립니다).
