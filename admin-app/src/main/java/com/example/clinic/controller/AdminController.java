package com.example.clinic.controller;

import com.example.clinic.service.PaymentService;
import com.example.clinic.service.ProcedureService;
import com.example.clinic.service.QnaService;
import com.example.clinic.service.QuickConsultationService;
import com.example.clinic.service.AdminReauthenticationService;
import java.security.Principal;
import java.nio.charset.StandardCharsets;
import org.springframework.stereotype.Controller;
import org.springframework.ui.Model;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PathVariable;
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
    private final AdminReauthenticationService reauthenticationService;

    public AdminController(QuickConsultationService consultationService, PaymentService paymentService,
                           QnaService qnaService, ProcedureService procedureService,
                           AdminReauthenticationService reauthenticationService) {
        this.consultationService = consultationService;
        this.paymentService = paymentService;
        this.qnaService = qnaService;
        this.procedureService = procedureService;
        this.reauthenticationService = reauthenticationService;
    }

    @GetMapping("/admin")
    public String dashboard(Model model) {
        model.addAttribute("consultations", consultationService.findRecentConsultations().stream()
            .map(AdminConsultationController.ConsultationListItem::from).toList());
        model.addAttribute("orders", paymentService.findRecentOrders().stream()
            .map(AdminPaymentController.PaymentListItem::from).toList());
        model.addAttribute("qnas", qnaService.findLatest());
        model.addAttribute("procedures", procedureService.findActiveProcedures());
        return "admin/dashboard";
    }

    @PostMapping("/admin/procedures/{id}/delete")
    public String deleteProcedure(
        @PathVariable Long id,
        @RequestParam String adminPassword,
        Principal principal,
        RedirectAttributes redirectAttributes
    ) {
        try {
            reauthenticationService.verify(principal, adminPassword);
            procedureService.delete(id);
            redirectAttributes.addFlashAttribute("message", "시술/상담 패키지가 삭제되었습니다.");
        } catch (IllegalArgumentException e) {
            redirectAttributes.addFlashAttribute("message", e.getMessage());
        }
        return "redirect:/admin";
    }

    @PostMapping("/admin/procedures/import")
    public String importProcedures(@RequestParam("file") MultipartFile file,
                                   @RequestParam String adminPassword,
                                   Principal principal,
                                   RedirectAttributes redirectAttributes) {
        try {
            reauthenticationService.verify(principal, adminPassword);
            if (file.isEmpty() || file.getSize() > 1024 * 1024) {
                throw new IllegalArgumentException("XML 파일은 1MB 이하만 등록할 수 있습니다.");
            }
            String originalName = file.getOriginalFilename();
            if (originalName == null || !originalName.toLowerCase(java.util.Locale.ROOT).endsWith(".xml")) {
                throw new IllegalArgumentException("XML 파일만 등록할 수 있습니다.");
            }
            String xml = new String(file.getBytes(), StandardCharsets.UTF_8);
            int count = procedureService.importFromXml(xml);
            redirectAttributes.addFlashAttribute("message", count + "개의 시술 상품이 등록되었습니다.");
        } catch (Exception e) {
            redirectAttributes.addFlashAttribute("message", "XML 등록에 실패했습니다. 입력 형식과 재인증 정보를 확인해 주세요.");
        }
        return "redirect:/admin";
    }
}
