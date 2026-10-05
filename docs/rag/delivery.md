# Days 21–25 delivery

Source of truth: [assignment](assignment.md), [agreed plan](implementation-plan.md).
Per-day implementation, measurements and limitations: [21](day21.md),
[22](day22.md), [23](day23.md), [24](day24.md), [25](day25.md).

The five feature branches are retained. All five are merged and pushed
to `challenge`; publication is checked against the remote refs in the external
delivery manifest.

| Day | Retained branch | Durable native demo | Duration | SHA-256 |
| --- | --- | --- | --- | --- |
| 21 | `feature/day-21` | `/home/kotdath/Videos/domovoy/day-21-demo.mp4` | 287.611444s | `2c725214a842a4ea06e479ed70e516b909dd2d8411e9a1448d310ccc0abf310e` |
| 22 | `feature/day-22` | `/home/kotdath/Videos/domovoy/day-22-demo.mp4` | 229.109722s | `81cd05a45c98dd014cf4c66ba7dc610c87a8bf2255bf865052385104e1da0bee` |
| 23 | `feature/day-23` | `/home/kotdath/Videos/domovoy/day-23-demo.mp4` | 467.359122s | `563d45ff0e4d34add33b969a1400aaa53495b1713de5b18f055852d1d75c10dd` |
| 24 | `feature/day-24` | `/home/kotdath/Videos/domovoy/day-24-demo.mp4` | 321.573656s | `984169131894e063442bf23ac1eaa836663350746973f87616f3b6c64d7a8e47` |

| 25 | `feature/day-25` | `/home/kotdath/Videos/domovoy/day-25-demo.mp4` | 3075.204044s | `9237714bbe1554255dfec98fdb9a3b91ac22b73785255d590ca95f04b20a52cb` |

Videos use H.264 at 1080×2400 without audio. Original whole clips, accessibility
snapshots, native request/answer diagnostics, independent AI review receipts and
checks are preserved outside Git in
`/home/kotdath/Videos/domovoy/evidence/day-21/` through `day-25/`.
Failed/intermediate model runs are preserved and labelled separately from final
verification; source quotation checks do not establish semantic correctness.

Large model weights, downloaded PDFs, videos, secrets and build products are
external artifacts. The day-25 video retains 38 whole clips with seekable chapters, including actual
failed replay trials. Its independent semantic score is 36/48 on Android and
39/48 for terminal Linux-native answers; citation validity is not factual accuracy.

The source ZIP is generated from the final tracked challenge
tree after all delivery checks; its filename contains the archived commit.
