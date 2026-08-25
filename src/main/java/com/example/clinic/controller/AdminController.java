package com.example.clinic.controller;

import com.example.clinic.service.PaymentService;
import com.example.clinic.service.ProcedureService;
import com.example.clinic.service.QnaService;
import com.example.clinic.service.QuickConsultationService;
import java.net.URI;
import java.net.http.HttpClient;
import java.net.http.HttpRequest;
import java.net.http.HttpResponse;
import java.nio.charset.StandardCharsets;
import java.time.Duration;
import org.springframework.stereotype.Controller;
import org.springframework.ui.Model;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.multipart.MultipartFile;
import org.springframework.web.servlet.mvc.support.RedirectAttributes;

@Controller
public class AdminController {

    private final QuickConsultationService consultationService;
    private final PaymentService paymentService;
    private final QnaService qnaService;
    private final ProcedureService procedureService;

    public AdminController(QuickConsultationService consultationService, PaymentService paymentService, QnaService qnaService, ProcedureService procedureService) {
        this.consultationService = consultationService;
        this.paymentService = paymentService;
        this.qnaService = qnaService;
        this.procedureService = procedureService;
    }

    @GetMapping("/admin")
    public String dashboard(Model model) {
        model.addAttribute("consultations", consultationService.findRecentConsultations());
        model.addAttribute("orders", paymentService.findRecentOrders());
        model.addAttribute("qnas", qnaService.findAll());
        return "admin/dashboard";
    }

    @PostMapping("/admin/procedures/import")
    public String importProcedures(@RequestParam("file") MultipartFile file, RedirectAttributes redirectAttributes) {
        try {
            String xml = new String(file.getBytes(), StandardCharsets.UTF_8);
            int count = procedureService.importFromXml(xml);
            redirectAttributes.addFlashAttribute("message", count + "개의 시술 상품이 등록되었습니다.");
        } catch (Exception e) {
            redirectAttributes.addFlashAttribute("message", "XML 등록 실패: " + e.getMessage());
        }
        return "redirect:/admin";
    }

    @PostMapping("/admin/ssrf-fetch")
    public String ssrfFetch(@RequestParam String url, Model model) {
        /*
         * VULNERABLE LAB - SF(SSRF):
         * 사용자가 입력한 URL을 화이트리스트/검증 없이 서버가 직접 요청한다.
         * file://, gopher://, 내부망(127.0.0.1, 169.254.169.254 등) 접근이 가능하다.
         */
        try {
            HttpClient client = HttpClient.newBuilder()
                .connectTimeout(Duration.ofSeconds(5))
                .build();
            HttpRequest request = HttpRequest.newBuilder(URI.create(url))
                .timeout(Duration.ofSeconds(10))
                .GET()
                .build();
            HttpResponse<String> response = client.send(request, HttpResponse.BodyHandlers.ofString());
            model.addAttribute("ssrfStatus", response.statusCode());
            model.addAttribute("ssrfBody", response.body());
        } catch (Exception ex) {
            model.addAttribute("ssrfStatus", -1);
            model.addAttribute("ssrfBody", "요청 실패: " + ex.getMessage());
        }
        model.addAttribute("consultations", consultationService.findRecentConsultations());
        model.addAttribute("orders", paymentService.findRecentOrders());
        model.addAttribute("qnas", qnaService.findAll());
        return "admin/dashboard";
    }
}
