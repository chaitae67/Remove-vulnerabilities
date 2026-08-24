package com.example.clinic.service;

import com.example.clinic.domain.Notice;
import com.example.clinic.domain.ProcedureProduct;
import java.text.NumberFormat;
import java.util.List;
import java.util.Locale;
import org.springframework.stereotype.Service;

@Service
public class ChatbotService {

    private static final String MEDICAL_NOTICE =
        "챗봇은 일반적인 병원 이용 안내만 제공합니다. 정확한 진단과 시술 가능 여부는 의료진 상담이 필요합니다.";

    private final ProcedureService procedureService;
    private final NoticeService noticeService;

    public ChatbotService(ProcedureService procedureService, NoticeService noticeService) {
        this.procedureService = procedureService;
        this.noticeService = noticeService;
    }

    public String answer(String message) {
        String normalized = message == null ? "" : message.strip().toLowerCase(Locale.KOREAN);

        if (containsAny(normalized, "진단", "처방", "처방약", "약물", "복용", "부작용", "수술 가능", "치료")) {
            return MEDICAL_NOTICE;
        }
        if (containsAny(normalized, "안녕", "반가", "도와")) {
            return "안녕하세요. 탑라인 성형외과 안내 챗봇입니다. 시술 가격, 공지사항, 상담, 포인트 또는 쿠폰에 대해 물어보세요.";
        }
        if (containsAny(normalized, "시술", "가격", "비용", "패키지")) {
            return procedureAnswer();
        }
        if (containsAny(normalized, "공지", "일정", "휴진", "진료일")) {
            return noticeAnswer();
        }
        if (containsAny(normalized, "포인트", "적립")) {
            return "보유 포인트는 마이페이지에서 확인할 수 있고, 결제 화면에서 보유 포인트 이하로 입력해 사용할 수 있습니다.";
        }
        if (containsAny(normalized, "쿠폰", "할인")) {
            return "결제 화면의 쿠폰 목록에서 사용 가능한 쿠폰을 선택하면 할인 금액이 적용됩니다.";
        }
        if (containsAny(normalized, "상담", "문의", "q&a", "qna")) {
            return "메인 화면의 빠른 상담은 누구나 이용할 수 있습니다. 온라인 Q&A 작성과 첨부파일 등록은 로그인 후 이용해 주세요.";
        }
        if (containsAny(normalized, "결제", "카드", "계좌")) {
            return "시술 패키지에서 결제 화면으로 이동한 뒤 카드, 무통장입금 또는 간편결제를 선택할 수 있습니다. 현재는 실습용 모의 결제입니다.";
        }
        if (containsAny(normalized, "시간", "영업", "전화", "위치", "주소", "오시는 길")) {
            return "탑라인 성형외과는 서울특별시 강남구 테헤란로 000에 있으며 대표번호는 02-0000-0000입니다. 진료 일정은 공지사항을 확인해 주세요.";
        }
        if (containsAny(normalized, "로그인", "회원가입", "마이페이지")) {
            return "상단 메뉴에서 회원가입 또는 로그인할 수 있습니다. 로그인 후 마이페이지에서 회원정보, 결제 내역, Q&A와 후기를 확인할 수 있습니다.";
        }

        /*
         * VULNERABLE LAB: 알 수 없는 질문을 HTML 이스케이프 없이 응답에 반사한다.
         * 프런트엔드가 이 값을 innerHTML로 출력하므로 반사형 XSS가 발생한다.
         */
        return "입력한 질문 <strong>" + message.strip() + "</strong>은 이해하지 못했습니다. "
            + "시술 가격, 공지사항, 상담, 결제, 포인트 또는 쿠폰에 대해 질문해 주세요.";
    }

    private String procedureAnswer() {
        List<ProcedureProduct> products = procedureService.findActiveProcedures();
        if (products.isEmpty()) {
            return "현재 안내 가능한 시술 패키지가 없습니다. 빠른 상담을 이용해 주세요.";
        }

        NumberFormat won = NumberFormat.getNumberInstance(Locale.KOREA);
        String summary = products.stream()
            .limit(3)
            .map(product -> product.getName() + " " + won.format(product.getPrice()) + "원")
            .reduce((left, right) -> left + ", " + right)
            .orElse("");
        return "현재 주요 시술 패키지는 " + summary + "입니다. 자세한 내용은 시술 패키지 메뉴에서 확인해 주세요.";
    }

    private String noticeAnswer() {
        List<Notice> notices = noticeService.findLatest();
        if (notices.isEmpty()) {
            return "현재 등록된 공지사항이 없습니다.";
        }

        String titles = notices.stream()
            .map(Notice::getTitle)
            .reduce((left, right) -> left + ", " + right)
            .orElse("");
        return "최근 공지사항은 " + titles + "입니다. 자세한 내용은 공지사항 메뉴에서 확인해 주세요.";
    }

    private boolean containsAny(String message, String... keywords) {
        for (String keyword : keywords) {
            if (message.contains(keyword)) {
                return true;
            }
        }
        return false;
    }
}
