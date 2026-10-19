[English](PRIVACY.md) · [Português](PRIVACY.pt-BR.md) · [Español](PRIVACY.es.md) · [Français](PRIVACY.fr.md) · [Deutsch](PRIVACY.de.md) · [简体中文](PRIVACY.zh-Hans.md) · [日本語](PRIVACY.ja.md) · **한국어**

# 개인정보 처리방침 — MacSpace

**최종 업데이트: 2026년 10월 19일 · MacSpace 1.0.0 이상에 적용**

MacSpace는 어떠한 사용 데이터도 수집, 저장, 전송하지 않습니다. 분석도, 원격 측정도, 충돌 보고도,
광고도 없습니다. MacSpace에는 계정 시스템이 없으므로 프로필을 만들거나 로그인할 필요가 없습니다.

이 문서는 MacSpace가 무엇을 읽고, 어디에 보관하며, 네트워크를 사용하는 유일한 경우가 언제인지
정확히 설명합니다.

---

## Mac에 남는 것

MacSpace는 디스크를 측정하고, 몇 가지 시스템 설정을 읽고, 사용자의 기기에 작은 파일 몇 개를 씁니다.
이 중 어떤 것도 Mac 밖으로 나가지 않습니다.

| 데이터 | 저장 위치 |
|---|---|
| 설정: 테마, 윈도우 선택, 켜져 있는 모듈, 모듈 옵션, 자동 정리, 알림 선택, 각 모듈이 마지막으로 보여 준 타일, 처음 실행 단계 | MacSpace의 macOS 환경설정(`UserDefaults`), `~/Library/Preferences/com.macspace.app.plist` |
| Sparkle 자체 설정: 업데이트를 자동으로 확인할지 여부와 마지막으로 확인한 시점 | 같은 환경설정 파일 |
| 정리 기록: 시점, 모듈, 확보한 크기, 시작 방식, 한 줄 요약 | `~/Library/Application Support/MacSpace/cleanup-history.json` |
| MacSpace가 확보를 요청했지만 macOS가 유지한 공간 | `~/Library/Application Support/MacSpace/purge-holdouts.json` |
| Debloat 저널: MacSpace가 바꾼 각 설정, 변경 전후의 값, macOS 빌드, 시점 | `~/Library/Application Support/MacSpace/debloat-journal.json`, 보조 프로그램이 한 변경은 `/Library/Application Support/MacSpace/debloat-journal.json` |
| Debloat 감시: macOS가 다시 켠 기능과 시점(최근 20건) | `~/Library/Application Support/MacSpace/debloat-watch.json` |
| 승인을 기다리는 상태의 Debloat 프로파일 | `~/Library/Application Support/MacSpace/Profiles/MacSpace.mobileconfig` |
| Apple Intelligence가 꺼져 있는 동안 MacSpace가 복원할 수 있도록 저장한 Siri 언어와 음성 | `~/Library/Application Support/MacSpace/ai-guard-saved-siri-settings.json` |
| Siri, 공간 사진, 로컬 통화 전사의 원래 설정(없는 값 포함) | `~/Library/Application Support/MacSpace/feature-settings/` |
| 복원을 위해 저장한 모델 소유자 요청(음성 및 언어 선택 포함) | `~/Library/Application Support/MacSpace/asset-owners/` |
| 시스템 전체 통화 전사의 원래 재정의 값 | `/Library/Application Support/MacSpace/phone-features.json` |
| Apple Intelligence 감시(켠 경우에만): 마지막으로 확인한 상태와 변경 로그 | `~/Library/Application Support/MacSpace/ai-watch-state.json` 및 `~/Library/Logs/MacSpace/ai-watch.jsonl` |
| macOS 구독 데이터베이스 백업(삭제된 계정에 남은 Apple Intelligence 구독을 제거한 경우에만) | `/Library/Application Support/MacSpace/backups/` |
| 업데이트 다운로드 | Sparkle의 캐시 폴더, `~/Library/Caches/com.macspace.app/` |

이 모든 것은 언제든지 삭제할 수 있습니다. 명령은 [README.ko.md](README.ko.md#제거)에 있습니다. 이 파일을
삭제하면 MacSpace는 기록과 설정을 잊습니다. Debloat 스위치가 꺼져 있는 동안 Debloat 저널을 삭제하면
MacSpace는 저장해 둔 원래 값을 더 이상 복원할 수 없고 대신 macOS의 기본값을 사용합니다. 먼저 **모두
켜기**를 누르세요.

### MacSpace가 읽는 것

MacSpace는 자신의 역할을 하기 위해 Mac에서 다음을 읽습니다. 그중 어떤 것도 어디로도 보내지 않습니다.

- **파일과 폴더의 이름과 크기.** 전체 디스크 접근을 허용하면 디스크 전체가 대상입니다. 문서, 사진, 메일,
  메시지의 내용은 읽지 않습니다. 그것들이 차지하는 공간을 측정합니다.
- **앱 캐시 안 파일의 날짜**(`~/Library/Caches`와, 전체 디스크 접근이 있을 때 각 앱 컨테이너의 캐시
  폴더 `~/Library/Containers/<app>/Data/Library/Caches`): 각 파일이 만들어지거나 변경되거나 처음 읽힌 시점과,
  Spotlight가 기록한 **각 앱이 마지막으로 열린 시점**. 어떤 캐시를 아무것도 사용하지 않는지 판단하기
  위해서입니다. 파일을 열지는 않습니다.
- **Homebrew 자체의 추정치**(Homebrew가 설치된 경우): MacSpace는 아무것도 바꾸지 않는 `brew cleanup -n`을
  Homebrew의 자동 업데이트와 분석을 끈 채로, Homebrew에 이미 패키지 목록이 있을 때만 실행합니다. 따라서
  Homebrew가 온라인에 접속하지 않습니다.
- **몇 가지 시스템 파일:** Apple Intelligence 사용 자격 파일, macOS의 에셋 구독 데이터베이스, 설치된 구성
  프로파일 목록, Apple 계정 데이터베이스(Siri의 iCloud 동기화가 켜져 있는지 알기 위한 읽기 전용).
- **이 Mac의 사용자 계정 이름.** 어느 계정이 Apple Intelligence를 켜 두고 있는지 알려 주기 위해서입니다.
- **macOS의 상태:** 버전과 빌드, 시스템 무결성 보호가 켜져 있는지, Mac이 기기 관리에 등록되어 있는지,
  실행 중인 프로세스의 이름(Debloat 스위치가 적용되었는지 확인하기 위한 것), macOS 자체의 분석 결정을
  기록한 시스템 로그의 몇 줄(분석 스위치가 작동했는지 확인하기 위한 것).

---

## MacSpace가 네트워크를 사용하는 때

MacSpace가 네트워크를 사용하는 목적은 하나, **업데이트**입니다. 분석도, 로그인도, 다른 연결도 없습니다.

### 업데이트를 확인할 때

MacSpace는 [Sparkle](https://sparkle-project.org)로 업데이트를 찾고 설치합니다. 다음 경우에 네트워크에
접속합니다:

- MacSpace 메뉴에서 **업데이트 확인…**을 선택하거나 설정에서 **지금 확인**을 선택할 때
- 자동 확인이 켜져 있다면 MacSpace가 실행되는 동안 하루에 한 번 정도

자동 확인은 설정에서 **자동으로 업데이트 확인**을 켜거나, 두 번째 실행부터 Sparkle이 한 번 묻는 질문에
'예'라고 답하기 전까지 꺼져 있습니다. 그전까지 MacSpace는 스스로 확인하지 않습니다. 소스에서 직접 빌드한
앱에는 업데이트 키가 없어 확인을 전혀 하지 않습니다.

확인은 GitHub에서 파일 하나를 요청합니다:

```
https://github.com/1architect/macspace-releases/releases/latest/download/appcast.xml
```

모든 웹 요청과 마찬가지로 GitHub는 IP 주소를 볼 수 있습니다. 요청에는 일반적인 `User-Agent` 헤더로
MacSpace의 이름과 버전, Sparkle의 버전도 담깁니다. MacSpace는 시스템 프로파일, 하드웨어 정보, 어떤
종류의 식별자도 보내지 않습니다. Sparkle의 선택적 시스템 프로파일은 켜져 있지 않습니다. 이 요청에 대한
GitHub의 처리는 [GitHub 개인정보 보호정책](https://docs.github.com/site-policy/privacy-policies/github-privacy-statement)에
나와 있습니다.

업데이트를 수락하면 Sparkle이 GitHub Releases에서 다운로드합니다. 모든 업데이트에는 서명이 있습니다.
Sparkle은 무엇이든 설치하기 전에 MacSpace 안의 공개 키로 서명을 확인합니다.

### MacSpace가 아닌 것

Apple Intelligence를 다시 켜면 macOS(MacSpace가 아님)가 해당 모델을 다운로드할 수 있습니다. 다운로드한
앱을 열 때 macOS가 Apple에 확인할 수 있습니다. 이는 macOS 자체의 연결입니다.

---

## MacSpace가 절대 하지 않는 일

- 파일 목록, 디스크 수치, 설정, 정리 기록, 계정 이름을 어디로도 보내지 않습니다.
- 문서, 사진, 메일, 메시지의 내용을 읽지 않습니다.
- 계정 생성이나 로그인을 요구하지 않습니다.
- 개발자에게도 다른 누구에게도 충돌이나 사용 현황을 보고하지 않습니다.

### 권한과 보조 프로그램에 대해

MacSpace는 몇 가지 승인을 요청하며, 각각 macOS 자체의 대화상자나 시스템 설정에서 처리되므로 암호를
절대 보지 않습니다:

- **전체 디스크 접근.** 디스크의 모든 항목을 측정하고 Apple Intelligence의 상태를 읽기 위해.
- **권한이 있는 보조 프로그램.** 관리자 권한이 필요한 몇 가지 작업을 하는 실행 데몬
  (`com.macspace.helper`). MacSpace와 같은 개발 팀이 서명한 클라이언트만 받아들이고 내장된 작업만
  실행합니다.
- **구성 프로파일.** Debloat 정책을 끌 때만.
- **알림.** 작업이 끝났음을 알려 주기 위해.

보조 프로그램과 프로파일이 할 수 있는 일은 [SECURITY.ko.md](SECURITY.ko.md)에 나와 있습니다.

---

## 어린이

MacSpace는 macOS용 유틸리티이며 어린이를 대상으로 하지 않습니다. 어떤 연령의 누구에게서도 개인정보를
수집하지 않습니다.

## 이 방침의 변경

MacSpace의 동작이 바뀌면 이 문서도 함께 바뀌고 맨 위의 날짜도 바뀝니다. 이 파일의 이력은 이 저장소에
공개되어 있으므로 무엇이 언제 바뀌었는지 정확히 볼 수 있습니다.

## 문의

개인정보에 관한 질문이나 이 문서의 내용에 대한 질문:

**dev@giomantovani.com.br**
