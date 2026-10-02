"""녹음 상황별 설정: 화자 이름 힌트, 요약 구성. 앱의 선택지와 요약 프롬프트가 함께 쓴다."""

SITUATIONS: dict[str, dict] = {
    "auto": {
        "title": "자동 판별", "icon": "wand.and.stars",
        "speakers": "", "capture": "mic",
        "sections": "",
    },
    "meeting": {
        "title": "대면 회의", "icon": "person.3",
        "speakers": "마이크 착용자를 A, 상대방을 B, C… 로", "capture": "mic",
        "sections": "## 한 줄 요약\n## 주요 내용\n(주제별 ### 소제목 + 불릿)\n## 결정 사항\n"
                    "## 할 일 (Action Items)\n| 담당 | 할 일 | 기한 |\n|---|---|---|",
    },
    "online": {
        "title": "온라인 회의", "icon": "video",
        "speakers": "채널로 정해진 '나'와 '상대방'(여러 명이면 맥락으로 상대방1, 상대방2…)", "capture": "mic+system",
        "sections": "## 한 줄 요약\n## 주요 내용\n(주제별 ### 소제목 + 불릿)\n## 결정 사항\n"
                    "## 할 일 (Action Items)\n| 담당 | 할 일 | 기한 |\n|---|---|---|",
    },
    "lecture": {
        "title": "강의·수업", "icon": "graduationcap",
        "speakers": "강사(대개 마이크 착용자)와 수강생(여러 명이면 수강생1, 수강생2…)", "capture": "mic",
        "sections": "## 한 줄 요약\n## 강의 개요\n(강의 주제·대상·흐름)\n## 핵심 개념\n(개념마다 ### 소제목 + 설명)\n"
                    "## 용어 정리\n| 용어 | 뜻 |\n|---|---|\n## 예시·실습\n## 질문과 답\n## 과제·다음 시간 안내",
    },
    "interview": {
        "title": "인터뷰·면접", "icon": "person.crop.circle.badge.questionmark",
        "speakers": "질문하는 쪽은 면접관(또는 인터뷰어), 답하는 쪽은 지원자(또는 인터뷰이)", "capture": "mic",
        "sections": "## 한 줄 요약\n## 대상자 정보\n(경력·배경 등 대화에서 드러난 것만)\n## 질문과 답변\n"
                    "(질문마다 **Q.** 한 줄 + **A.** 요약)\n## 평가 포인트\n(강점·우려·확인 필요)\n## 조건·처우 논의\n## 후속 조치",
    },
    "consult": {
        "title": "상담·고객 미팅", "icon": "bubble.left.and.bubble.right",
        "speakers": "상담자(또는 우리 쪽)와 고객(또는 상대 쪽)", "capture": "mic",
        "sections": "## 한 줄 요약\n## 상대의 요구·문제\n## 제안·답변한 내용\n## 합의 사항\n"
                    "## 할 일 (Action Items)\n| 담당 | 할 일 | 기한 |\n|---|---|---|",
    },
    "brainstorm": {
        "title": "브레인스토밍", "icon": "lightbulb",
        "speakers": "A, B, C… (말투·역할로 구분)", "capture": "mic",
        "sections": "## 한 줄 요약\n## 나온 아이디어\n(주제별 ### 묶음 + 불릿, 낸 사람 표시)\n## 유망한 아이디어\n"
                    "## 반론·리스크\n## 다음에 해 볼 것",
    },
    "seminar": {
        "title": "발표·세미나", "icon": "person.wave.2",
        "speakers": "발표자와 질문자(여러 명이면 질문자1, 질문자2…)", "capture": "mic",
        "sections": "## 한 줄 요약\n## 발표자·주제\n## 핵심 메시지\n## 주요 내용\n(흐름대로 ### 소제목 + 불릿)\n"
                    "## 인상적인 말\n(> 인용)\n## 질의응답",
    },
    "call": {
        "title": "통화", "icon": "phone",
        "speakers": "나와 상대방", "capture": "mic+system",
        "sections": "## 한 줄 요약\n## 요점\n## 약속·결정\n## 할 일\n| 담당 | 할 일 | 기한 |\n|---|---|---|",
    },
    "memo": {
        "title": "개인 메모", "icon": "note.text",
        "speakers": "말하는 사람 한 명(나)", "capture": "mic",
        "sections": "## 한 줄 요약\n## 정리된 생각\n(주제별 ### 소제목 + 불릿)\n## 아이디어\n## 할 일",
    },
}


def get(key: str | None) -> dict:
    return SITUATIONS.get(key or "auto", SITUATIONS["auto"])


def choices_text() -> str:
    """자동 판별 프롬프트용 목록"""
    return "\n".join(f"- {k}: {v['title']}" for k, v in SITUATIONS.items() if k != "auto")
