package com.example.clinic.controller;

import java.util.List;
import java.util.Map;

import org.springframework.stereotype.Controller;
import org.springframework.ui.Model;
import org.springframework.web.bind.annotation.GetMapping;

import com.example.clinic.service.ProcedureService;

@Controller
public class ClinicPageController {

    private final ProcedureService procedureService;

    public ClinicPageController(ProcedureService procedureService) {
        this.procedureService = procedureService;
    }

    @GetMapping("/clinic")
    public String clinic() {
        return "clinic/about";
    }

    @GetMapping("/eye")
    public String eye(Model model) {
        return category(model, "EYE", "눈성형", "눈의 선과 비율을 세심하게 살펴 또렷하고 자연스러운 인상을 설계합니다.",
            List.of(card("쌍꺼풀 상담", "라인과 눈꺼풀 상태를 함께 확인합니다."), card("눈매교정 상담", "눈 뜨는 힘과 인상의 균형을 살펴봅니다."), card("트임 상담", "눈의 가로·세로 비율을 종합적으로 진단합니다.")));
    }

    @GetMapping("/nose")
    public String nose(Model model) {
        return category(model, "NOSE", "코성형", "얼굴 중심의 높이와 각도를 고려해 정면과 측면의 균형을 함께 진단합니다.",
            List.of(card("콧대 상담", "얼굴형에 맞는 높이와 시작점을 살펴봅니다."), card("코끝 상담", "코끝의 각도와 지지 구조를 확인합니다."), card("기능·재수술 상담", "현재 상태와 이전 수술 이력을 꼼꼼히 확인합니다.")));
    }

    @GetMapping("/contour")
    public String contour(Model model) {
        return category(model, "CONTOUR & LIFTING", "윤곽·리프팅", "얼굴의 정면·측면 비율과 피부 상태를 함께 살펴 필요한 방법을 제안합니다.",
            List.of(card("얼굴 윤곽 상담", "광대·턱선·턱끝의 전체 비율을 진단합니다."), card("리프팅 상담", "피부 두께와 처짐 정도에 맞춰 상담합니다."), card("비수술 윤곽 상담", "회복과 일정을 고려한 선택지를 안내합니다.")));
    }

    @GetMapping("/lifting")
    public String lifting(Model model) {
        return category(model, "LIFTING", "리프팅", "피부 두께와 처짐 정도, 원하는 회복 일정을 함께 고려해 적합한 방향을 상담합니다.",
            List.of(card("수술 리프팅 상담", "처짐의 위치와 범위를 세심하게 확인합니다."), card("비수술 리프팅 상담", "피부 상태와 일정을 고려한 방법을 안내합니다."), card("복합 관리 상담", "윤곽과 피부 탄력을 함께 살펴봅니다.")));
    }

    @GetMapping("/body")
    public String body(Model model) {
        return category(model, "BODY", "바디성형", "체형과 생활 습관, 원하는 라인을 종합해 개인별 상담 계획을 세웁니다.",
            List.of(card("지방흡입 상담", "부위별 지방 분포와 피부 탄력을 확인합니다."), card("바디라인 상담", "전체 비율을 고려해 우선순위를 정합니다."), card("회복 계획", "일상 복귀 일정과 관리 과정을 안내합니다.")));
    }

    @GetMapping("/aftercare")
    public String aftercare(Model model) {
        return category(model, "AFTER CARE", "사후관리", "상담부터 회복까지 이어지는 단계별 관리로 편안한 회복을 돕습니다.",
            List.of(card("경과 확인", "회복 단계에 맞춰 상태를 확인합니다."), card("붓기·흉터 관리", "개인별 회복 상태에 맞는 관리를 안내합니다."), card("일상 복귀 안내", "주의사항과 생활 관리 방법을 설명합니다.")));
    }

    @GetMapping("/events")
    public String events(Model model) {
        model.addAttribute("procedures", procedureService.findActiveProcedures());
        return "clinic/events";
    }

    private String category(Model model, String eyebrow, String title, String description, List<Map<String, String>> cards) {
        model.addAttribute("eyebrow", eyebrow);
        model.addAttribute("title", title);
        model.addAttribute("description", description);
        model.addAttribute("cards", cards);
        return "clinic/category";
    }

    private Map<String, String> card(String title, String description) {
        return Map.of("title", title, "description", description);
    }
}
