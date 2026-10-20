[English](../../../SECURITY.md) · [Português](../pt-BR/SECURITY.md) · [Español](../es/SECURITY.md) · [Français](../fr/SECURITY.md) · [Deutsch](../de/SECURITY.md) · [简体中文](../zh-Hans/SECURITY.md) · [日本語](../ja/SECURITY.md) · **한국어**

# 보안 정책

MacSpace는 macOS용 무료 오픈 소스(MIT) 앱입니다. 일반 사용자 계정으로 실행됩니다. 관리자 권한이 필요한
몇 가지 작업에는 한 번만 승인하면 되는 권한 있는 보조 프로그램을 사용합니다. 사용자에 대한 데이터를
수집하지 않습니다. 이 문서는 MacSpace가 Mac에서 무엇을 건드리는지, 그리고 문제를 어떻게 신고하는지
정확히 설명합니다.

## 취약점 신고

GitHub의 비공개 취약점 신고를 이용하세요:
[취약점 신고](https://github.com/1architect/macspace-releases/security/advisories/new).
또는 세부 내용과 재현 단계를 적어 **dev@giomantovani.com.br**로 이메일을 보내세요. 보안 신고를 위해
공개 이슈를 열지 마세요. 며칠 안에 접수 확인을 받게 됩니다.

해당되는 것: 다른 프로그램이 보조 프로그램에 원하지 않는 작업을 시킬 수 있게 하는 문제, MacSpace가
삭제하거나 바꾸면 안 되는 것을 삭제하거나 바꾸게 하는 문제, 릴리스 서명 없이 업데이트가 설치되게 하는
문제.

## 지원되는 버전

보안 수정은 최신 릴리스에만 반영됩니다. 항상 [Releases](https://github.com/1architect/macspace-releases/releases/latest)의
최신 버전으로 **업데이트 확인…** 또는 `brew upgrade --cask macspace`로 업데이트하세요(Homebrew가
건너뛰면 `--greedy`를 추가하세요. MacSpace가 스스로 업데이트하기 때문입니다).

## MacSpace가 Mac에서 하는 일

### 네트워크

MacSpace는 업데이트라는 한 가지 목적으로만 네트워크에 연결합니다. **업데이트 확인…**(또는 설정의
**지금 확인**)을 선택할 때, 그리고 **자동으로 업데이트 확인**을 켰다면 실행되는 동안 하루에 한 번 정도,
GitHub에서 릴리스와 함께 호스팅되는 업데이트 피드(`appcast.xml`)를 읽습니다. 업데이트를 수락하면
GitHub Releases에서 새 버전을 다운로드합니다. 사용자에 대한 어떤 정보도 전송되지 않으며, Sparkle의
선택적 시스템 프로파일은 켜져 있지 않습니다.

분석도, 원격 측정도, 충돌 보고도 없습니다. 자세한 내용은 [개인정보 처리방침](PRIVACY.md)에 있습니다.

### 데이터가 저장되는 위치

모든 것은 Mac에 남습니다. MacSpace의 파일은 `~/Library/Application Support/MacSpace/`,
`~/Library/Logs/MacSpace/`, 환경설정 파일 `~/Library/Preferences/com.macspace.app.plist`, 그리고
보조 프로그램이 쓰는 것은 `/Library/Application Support/MacSpace/`에 있습니다.
[개인정보 처리방침](PRIVACY.md)에 각 파일이 나와 있습니다. 어느 것도 어디로도 업로드되지 않습니다.

### MacSpace가 삭제하는 것

| 대상 | 위치 | 실행 주체 |
|---|---|---|
| 닫혀 있는 앱의 캐시 | 사용자별 시스템 캐시 폴더(`/var/folders/…/C`), Apple 자체의 것은 제외. `~/Library/Application Support`의 Chromium 또는 Electron 프로파일 안에 있는 `Cache`, `Code Cache`, `GPUCache`, `DawnCache`, `DawnGraphiteCache`, `DawnWebGPUCache`, `GrShaderCache`, `ShaderCache`, `CachedData` 폴더. | 앱(사용자 권한으로) |
| 7일 넘은 진단 및 충돌 보고서 | `/Library/Logs/DiagnosticReports`와 `~/Library/Logs/DiagnosticReports`. 삭제할 권한이 없는 파일은 건너뜁니다. | 앱(사용자 권한으로) |
| 미사용 시스템 에셋, 해제된 Apple Intelligence 모델, 앱이 지울 수 있는 파일로 표시한 항목 | macOS 자체의 정리 서비스(CacheDelete). MacSpace는 수명이 짧은 하위 프로세스에서 요청하므로, 그곳의 실패가 앱을 중단시키지 않습니다. | macOS |
| 클라우드 파일의 로컬 복사본 | 한 번에 클라우드 폴더 하나(`~/Library/CloudStorage/…` 또는 iCloud Drive). 업로드되었고 충돌이 없는 파일만. 파일은 클라우드에 그대로 남습니다. | 앱(사용자 권한으로) |
| 문서 버전 기록 | `/System/Volumes/Data/.DocumentRevisions-V100` | 보조 프로그램 |
| macOS 업데이트의 남은 파일 | `/System/Volumes/Data/macOS Install Data`, 설치된 시스템보다 오래된 경우에만. `Locked Files` 폴더는 남습니다. | 보조 프로그램 |
| 끝내지 못한 배경화면 및 화면 보호기 다운로드 | `/private/var/folders/*/*/T/com.apple.idleassetsd` 바로 아래에서 3일 동안 변경되지 않은 `CFNetworkDownload_*.tmp` 파일. 일반 파일만: 링크와 하위 폴더는 거부됩니다. | 보조 프로그램 |
| macOS가 앱을 확인할 때 만든 복사본 | `/var/folders/…/X/<app>.code_sign_clone`, 자체 공간(이전 버전의 것)을 차지하고 있으며, 앱이 닫혀 있고 그곳에서 실행 중인 것이 없을 때만. | 앱(사용자 권한으로) |
| 시스템 로그 | `/private/var/db/diagnostics`와 `/private/var/db/uuidtext`, Apple 자체의 `log erase --all` 및 `log erase --uuidtext` 사용. | 보조 프로그램 |
| 충돌 보고서용 심벌 | `/System/Library/Caches/com.apple.coresymbolicationd`의 모든 내용(폴더는 남음). 그런 다음 공간이 돌아오도록 `coresymbolicationd`를 중지합니다. macOS가 캐시를 다시 만듭니다. | 보조 프로그램 |
| 휴지통 | `~/.Trash`의 모든 항목. 잠겨 있거나 다른 계정의 항목은 남습니다. | 앱(사용자 권한으로) |
| Time Machine의 로컬 스냅샷 | `tmutil deletelocalsnapshots <date>`, 한 번에 하나의 날짜씩: 가장 최근 것과 가장 최근 백업의 것을 제외한 전부. 백업이 실행 중일 때는 하지 않습니다. | 앱(사용자 권한으로) |
| Time Machine 백업 디스크의 백업 | `tmutil delete`, 사용자가 선택한 것, 최신 백업은 제외, Time Machine이 사용하는 연결된 디스크에서. 백업이 실행 중일 때는 하지 않습니다. | 보조 프로그램 |

휴지통으로 가는 것은 없습니다. 캐시, 시스템 에셋, 지울 수 있는 파일은 필요할 때 다시 만들어지거나 다시
다운로드되고, 클라우드 복사본은 파일을 열 때 다시 다운로드됩니다. 보고서, 버전 기록, 업데이트 잔여 파일,
시스템 로그, 휴지통 항목, 스냅샷, 백업은 되돌릴 수 없습니다. 이 모든 작업은 개별 앱 캐시의 **확보**
버튼을 제외하고 먼저 확인을 요청합니다.

### MacSpace가 바꾸는 것(Debloat)

각 변경은 먼저 저널에 기록되므로 **모두 켜기**를 누르거나 기능을 다시 켜서 되돌릴 수 있습니다.

| 스위치 | 바뀌는 것 | 실행 주체 |
|---|---|---|
| 개인 맞춤형 광고 | `com.apple.AdLib`, 키 `allowApplePersonalizedAdvertising` | 앱(사용자 권한으로) |
| Siri 및 받아쓰기 향상 | `com.apple.assistant.support`, 키 `Siri Data Sharing Opt-In Status` | 앱(사용자 권한으로) |
| 충돌 보고서 대화상자 | `com.apple.DiagnosticsReporter`와 `com.apple.ReportGPURestart`에 대한 launchd 재정의 | 앱(사용자 권한으로) |
| Apple과 분석 공유(macOS 정식 빌드) | `/Library/Application Support/CrashReporter/DiagnosticMessagesHistory.plist`, 키 `AutoSubmit` 및 `ThirdPartyDataSubmit` | 보조 프로그램 |
| Siri AI, 시각적 지능 | `/Library/Preferences/FeatureFlags/Domain/`의 기능 플래그 재정의 | 보조 프로그램 |
| 응답 중단 추적(tailspin) | `tailspin disable`, 되돌릴 때는 `tailspin enable` | 보조 프로그램 |
| 정책(다섯 개, macOS 베타에서는 여섯 개) | 구성 프로파일 하나, `com.macspace.policies`(아래 참조) | 시스템 설정에서 사용자가 승인 |

스위치를 다시 켜지 않고 앱을 삭제하면 이러한 변경은 그대로 남습니다.

### Apple Intelligence

**Apple Intelligence** 스위치는 `com.apple.assistant.backedup`의 키 `Session Language`, 즉 Siri의 언어를
바꿉니다. 끄면 Siri에는 시스템과 다른 언어가 설정되고, Siri 음성(`Output Voice`)은 그대로 둡니다.
MacSpace는 둘 다 `~/Library/Application Support/MacSpace/ai-guard-saved-siri-settings.json`에 저장하고,
Apple Intelligence를 켜거나 변경이 적용되지 않았을 때 복원합니다. 스위치를 끈 뒤에도 macOS가 모델을
유지하면, MacSpace는 macOS가 모델을 해제하도록 언어를 시스템 언어로 설정했다가 되돌릴 수 있으며, 이
작업에는 약 1분이 걸립니다. Siri의 iCloud 동기화가 켜져 있으면 이러한 변경은 같은 Apple 계정의 다른
기기에도 전달됩니다. MacSpace는 그 동기화를 끌 수 없으며, 어디서 끄는지 알려 줍니다.

### 통화 전사

Siri 및 Apple Intelligence의 통화 전사 스위치는
`/Library/Preferences/FeatureFlags/Domain/TelephonyUtilities.plist`의 고정된 TelephonyUtilities 재정의 다섯 개를
사용합니다: 통화 녹음, 통화 선별, FaceTime 자막 전달, Mac의 오디오/비디오 번역 게이트. 인증된 보조 프로그램은
변경을 쓰기 전에 원래 항목을 `/Library/Application Support/MacSpace/phone-features.json`에 저장합니다.
변경은 재시동 후에 적용되며, 실행 중인 게이트는 따로 확인합니다. 다시 켜면 관련 없는 재정의는 그대로 둔 채
그 원래 항목을 복원합니다. 보조 프로그램은 MacSpace 밖에서 바뀐 항목을 덮어쓰지 않고 거부합니다. 이
컨트롤은 구성 프로파일을 설치하지 않으며 Siri의 Session Language도 바꾸지 않습니다. 해당 보조 프로그램
작업은 켜기/끄기 의도만 받으며, 임의의 경로, 도메인, 키는 받지 않습니다.

### 기능 모델

별도의 Siri 및 공간 사진 스위치는 기능을 끄기 전에 원래 설정을 저장합니다. Siri가 꺼져 있는 동안 저장된
Siri 음성은 지워지고, Session Language는 보존됩니다. 통화 전사는 로컬 녹음, 선별, 자막 설정도 함께
끕니다. 원래 설정은 `~/Library/Application Support/MacSpace/feature-settings/`에 보관됩니다.

모델 요청은 해당 모델을 소유한 Apple 프레임워크를 통해, 사용자 권한으로 실행되는 별도의 MacSpace
프로세스에서 해제되며, 앱이나 보조 프로그램 안에서는 절대 하지 않습니다. 그 프로세스는 각 메서드를
호출하기 전에 MacSpace가 검토한 메서드와 대조하고, 차이가 있으면 중지합니다. 롤백 객체는 사용자만 읽을 수
있도록 `~/Library/Application Support/MacSpace/asset-owners/` 아래에 저장됩니다. 이러한 기능 및 언어 모델
정리는 실제 구독 데이터베이스를 편집하거나 모델 페이로드를 직접 삭제하지 않습니다. 물리적 정리는 보호
장치가 있는 기존 macOS 정리 서비스를 사용합니다. Apple Intelligence의 상태를 읽을 수 없는 동안, 그리고
Apple Intelligence가 켜져 있을 때 macOS가 시스템 에셋을 다운로드하는 동안에는 기다리며, 받아쓰기가 켜져
있는 동안에는 다른 계정의 요청과 공유 음성 모델을 유지합니다. 사용하지 않는 언어 데이터는 Apple
Intelligence가 꺼져 있을 때만 해제됩니다.

MacSpace가 열려 있는 동안 명시적으로 꺼진 기능은 5분마다 확인되며, macOS가 모델을 다시 요청하면 사용하지
않는 모델이 다시 정리됩니다. 기능을 다시 켜거나 MacSpace의 제거 프로그램을 사용하면 저장된 설정과 모델
요청이 복원되며, macOS가 모델을 다시 다운로드할 수 있습니다. 중단되었거나 충돌하는 소유자 작업은 반복
요청 전에 확인됩니다. 이 컨트롤은 macOS 27의 모든 릴리스에서 작동하며, 각 요청 전에 별도의 프로세스가
호출할 Apple 메서드를 확인합니다. 시스템 데이터의 미사용 언어 에셋은 일회성 정리를 사용하며, 그 작업은
맞춤법 검사나 사전을 끄지 않습니다.

### 권한

각 프롬프트는 macOS가 처리하므로 MacSpace는 암호를 절대 보지 않습니다.

| 권한 | 위치 | MacSpace의 용도 |
|---|---|---|
| 전체 디스크 접근 | 시스템 설정 > 개인정보 보호 및 보안 | macOS가 보호하는 폴더 측정 및 Apple Intelligence 상태 읽기 |
| 권한이 있는 보조 프로그램 | 시스템 설정 > 일반 > 로그인 항목 및 확장 프로그램 | 아래의 작업 |
| 구성 프로파일 | 시스템 설정 > 일반 > 기기 관리 | Debloat 정책을 끌 때만 |
| 알림 | macOS가 물어봅니다 | 작업이 끝났음을 알려 주기 위해 |

### 권한이 있는 보조 프로그램

보조 프로그램은 실행 데몬 `com.macspace.helper`이며, 앱 안에서 macOS에 등록됩니다. MacSpace가 무언가를
요청하면 launchd가 시작합니다. root로 실행되며, macOS가 확인하는 다음 코드 서명 요구 사항을 만족하는
프로그램의 연결만 받아들입니다:

```
anchor apple generic and (identifier "com.macspace.app" or identifier "com.macspace.cli")
and certificate leaf[subject.OU] = "<the developer's team ID>"
```

요구 사항이 없으면 시작을 거부합니다. 내장된 이름 있는 작업만 실행합니다. 호출하는 쪽이 명령을 보낼 수
없습니다. 업데이트로 앱이 교체되면 보조 프로그램이 이를 알아차리고 물러나, 새 프로그램이 시작되게 합니다.

| 작업 | 하는 일 | 제한 |
|---|---|---|
| `systemdata.measure` | 폴더 크기 | 읽기 전용. `/private/var`, `/private/tmp`, `/Library`, `/System/Library`, Data 볼륨의 루트, `/opt` 아래에서만, 홈 폴더는 절대 아님. 크기만, 내용은 아님. |
| `systemdata.versions.delete` | 문서 버전 기록 삭제 | 먼저 `revisiond`를 중지하고, macOS가 거부하면 일시 중지합니다. 폴더가 아니라 저장소의 내용을 삭제한 다음 `revisiond`를 다시 시작합니다. 중지할 수 없으면 아무것도 삭제하지 않습니다. |
| `systemdata.staged-update.delete` | 업데이트 잔여 파일 삭제 | 폴더가 설치된 시스템보다 오래된 경우에만. `Locked Files`는 유지합니다. |
| `systemdata.wallpaper-downloads.delete` | 끝내지 못한 배경화면 및 화면 보호기 다운로드 삭제 | 경로를 받지 않음: `/private/var/folders/*/*/T/com.apple.idleassetsd`를 직접 찾으며 링크를 따라가지 않습니다. 그 바로 아래에서 3일 동안 변경되지 않은 `CFNetworkDownload_*.tmp`라는 이름의 일반 파일만 삭제합니다. |
| `systemdata.unified-log.erase` | 시스템 로그 지우기 | 인수를 받지 않음. Apple의 `/usr/bin/log erase --all`을 실행하고 이어서 `log erase --uuidtext`를 실행할 뿐입니다. |
| `systemdata.symbolication-cache.delete` | 충돌 보고서용 심벌 삭제 | 인수를 받지 않음. `/System/Library/Caches/com.apple.coresymbolicationd`만, 링크를 따라가지 않고 열며, 그 안의 내용을 삭제하되 폴더는 절대 삭제하지 않고, 이어서 `coresymbolicationd`를 중지합니다(`kill -TERM`, 5초 후 `-KILL`). |
| `timemachine.backups.delete` | Time Machine 백업 디스크에서 백업 삭제 | Time Machine이 연결됨으로 표시하는 디스크에서만, 그곳에서 직접 찾은 날짜만, 최신 백업은 절대 아니며, 백업이 실행 중이거나 그 여부를 알 수 없을 때는 하지 않습니다. `/usr/bin/tmutil delete`를 실행합니다. |
| `debloat.status`, `.apply`, `.revert` | Debloat 항목 읽기, 끄기, 켜기 | 내장 카탈로그의 컨트롤 식별자만. 그 외에는 없음. |
| `debloat.removeProfile` | MacSpace 프로파일 제거 | 식별자 `com.macspace.policies`와 `com.macspace.policies.…`만. 다른 프로파일은 거부됩니다. |
| `siri.orphan-subscriptions.plan`, `.execute` | 더 이상 존재하지 않는 계정의 Apple Intelligence 구독을 찾아 제거 | 먼저 데이터베이스를 `/Library/Application Support/MacSpace/backups/`에 백업하고, 하나의 트랜잭션으로 변경하며, 어떤 로컬 계정과도 일치하지 않는 행만 건드리고, 계정 목록이 이상해 보이면 거부합니다. 앱에는 아직 이를 위한 버튼이 없습니다. |
| `helper.ping` | 응답하여 앱이 보조 프로그램이 작동 중임을 알게 함 | 없음 |

앱 번들 안의 명령줄 도구 `MacSpaceCli`도 보조 프로그램과 통신할 수 있습니다. 같은 팀으로 서명되어 있습니다.

### 구성 프로파일

Debloat의 정책은 구성 프로파일로만 강제할 수 있는 설정입니다. MacSpace는 끈 모든 정책을 담은 프로파일
`com.macspace.policies`(**MacSpace: policies**로 표시되며 조직은 "MacSpace") 하나를 만듭니다. 프로파일을
열면 사용자가 시스템 설정 > 일반 > 기기 관리에서 승인합니다. 승인하면 이전 것을 대체합니다. 제거할 수
없도록 표시되어 있지 않습니다. 마지막 정책을 다시 켜면 승인할 필요 없이 보조 프로그램을 통해
제거됩니다. 시스템 설정에서 직접 제거할 수도 있습니다.

### 코드 서명 및 업데이트

MacSpace는 Apple Developer ID로 서명되고 하드닝된 런타임이 적용되며 Apple의 공증을 받았습니다.
공증 티켓이 앱에 스테이플되어 있어 오프라인에서도 열립니다. Sparkle 자체 구성 요소도 같은 ID로
서명되어 있습니다.

업데이트도 EdDSA 키로 서명됩니다. 그 공개 키는 MacSpace 안에 있으며(`SUPublicEDKey`), Sparkle은 설치
전에 모든 다운로드를 이에 대해 확인합니다. 그 키의 비공개 부분과 서명 ID는 이 저장소에 없습니다. 공개 키
없이 빌드한 MacSpace는 업데이트를 확인하지 않습니다.

## 다운로드 확인

`MacSpace-x.y.z.dmg`와 `MacSpace-x.y.z.dmg.sha256`을 한 폴더에 넣으세요:

```bash
shasum -a 256 -c MacSpace-x.y.z.dmg.sha256
```

그런 다음 MacSpace를 응용 프로그램으로 드래그한 뒤:

```bash
codesign -dv --verbose=4 /Applications/MacSpace.app
codesign --verify --deep --strict --verbose=2 /Applications/MacSpace.app
spctl -a -vv /Applications/MacSpace.app
xcrun stapler validate /Applications/MacSpace.app
```

`Authority=Developer ID Application`, `TeamIdentifier=J45ZXS2ZF6`, `runtime` 플래그,
`Notarization Ticket=stapled`가 보여야 하며, `spctl`은 `accepted`와 `source=Notarized Developer ID`를
표시해야 합니다.

## 완전히 제거

MacSpace에는 제거 프로그램이 있습니다. 메뉴 막대에서 **MacSpace** > **MacSpace 정보**를 선택한 다음
**제거…**를 선택하세요. 각 모듈의 설정을 복원하고, 보조 프로그램을 제거하고, MacSpace를 휴지통으로
옮깁니다. 직접 하려면 전체 단계가 [README](README.md#제거)에 있습니다. 요약하면:

1. **Debloat**에서 **모두 켜기**를 누릅니다. 재정의와 그것이 만든 프로파일이 제거됩니다.
2. 프로파일 **MacSpace: policies**가 시스템 설정 > 일반 > 기기 관리에 아직 있다면 제거하세요.
3. MacSpace를 종료합니다. 시스템 설정 > 일반 > 로그인 항목 및 확장 프로그램에서 끄거나,
   `/Applications/MacSpace.app/Contents/MacOS/MacSpaceCli helper --unregister`를 실행하세요.
4. 앱을 제거합니다: `brew uninstall --cask macspace` 또는 **MacSpace**를 휴지통으로 드래그하세요.
5. 데이터와 환경설정을 제거합니다:
   ```bash
   rm -rf ~/Library/Application\ Support/MacSpace ~/Library/Logs/MacSpace ~/Library/Caches/com.macspace.app
   defaults delete com.macspace.app
   sudo rm -rf /Library/Application\ Support/MacSpace
   ```
6. 시스템 설정 > 개인정보 보호 및 보안 > 전체 디스크 접근 권한에서 MacSpace를 제거합니다.
