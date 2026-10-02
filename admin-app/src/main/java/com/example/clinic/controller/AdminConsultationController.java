package com.example.clinic.controller;

import com.example.clinic.domain.QuickConsultation;
import com.example.clinic.service.QuickConsultationService;
import java.time.LocalDate;
import java.util.List;
import java.time.LocalDateTime;
import com.example.clinic.util.PrivacyMasker;
import com.example.clinic.service.AdminReauthenticationService;
import java.security.Principal;
import org.springframework.format.annotation.DateTimeFormat;
import org.springframework.stereotype.Controller;
import org.springframework.ui.Model;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.servlet.mvc.support.RedirectAttributes;

@Controller
public class AdminConsultationController {

    private final QuickConsultationService consultationService;
    private final AdminReauthenticationService reauthenticationService;

    public AdminConsultationController(QuickConsultationService consultationService,
                                       AdminReauthenticationService reauthenticationService) {
        this.consultationService = consultationService;
        this.reauthenticationService = reauthenticationService;
    }

    @GetMapping("/admin/consultations")
    public String list(@RequestParam(required = false) String keyword, Model model) {
        List<QuickConsultation> consultations = consultationService.search(keyword);
        model.addAttribute("consultations", consultations.stream().map(ConsultationListItem::from).toList());
        model.addAttribute("keyword", keyword);
        return "admin/consultations";
    }

    public static final class ConsultationListItem {
        private final Long id;
        private final String name;
        private final String phone;
        private final String area;
        private final String preferredContact;
        private final LocalDate preferredDate;
        private final boolean hasAdminNote;
        private final LocalDateTime createdAt;

        private ConsultationListItem(Long id, String name, String phone, String area,
                                     String preferredContact, LocalDate preferredDate,
                                     boolean hasAdminNote, LocalDateTime createdAt) {
            this.id = id;
            this.name = name;
            this.phone = phone;
            this.area = area;
            this.preferredContact = preferredContact;
            this.preferredDate = preferredDate;
            this.hasAdminNote = hasAdminNote;
            this.createdAt = createdAt;
        }

        static ConsultationListItem from(QuickConsultation item) {
            return new ConsultationListItem(item.getId(), PrivacyMasker.name(item.getName()),
                PrivacyMasker.phone(item.getPhone()), item.getArea(), item.getPreferredContact(),
                item.getPreferredDate(), item.getAdminNote() != null && !item.getAdminNote().isBlank(), item.getCreatedAt());
        }

        public Long getId() { return id; }
        public String getName() { return name; }
        public String getPhone() { return phone; }
        public String getArea() { return area; }
        public String getPreferredContact() { return preferredContact; }
        public LocalDate getPreferredDate() { return preferredDate; }
        public boolean isHasAdminNote() { return hasAdminNote; }
        public LocalDateTime getCreatedAt() { return createdAt; }
    }

    @GetMapping("/admin/consultations/{id}")
    public String detail(@PathVariable Long id, Model model) {
        model.addAttribute("consultation", consultationService.findById(id));
        return "admin/consultation-detail";
    }

    @PostMapping("/admin/consultations/{id}")
    public String update(
        @PathVariable Long id,
        @RequestParam String name,
        @RequestParam String phone,
        @RequestParam(required = false) String area,
        @RequestParam(required = false) String preferredContact,
        @RequestParam(required = false) @DateTimeFormat(iso = DateTimeFormat.ISO.DATE) LocalDate preferredDate,
        @RequestParam(required = false) String message,
        @RequestParam(required = false) String adminNote,
        @RequestParam String adminPassword,
        Principal principal,
        RedirectAttributes redirectAttributes
    ) {
        try {
            reauthenticationService.verify(principal, adminPassword);
            consultationService.update(id, name, phone, area, preferredContact, preferredDate, message, adminNote);
            redirectAttributes.addFlashAttribute("message", "상담 신청 내역이 수정되었습니다.");
        } catch (IllegalArgumentException e) {
            redirectAttributes.addFlashAttribute("error", e.getMessage());
        }
        return "redirect:/admin/consultations/" + id;
    }

    @PostMapping("/admin/consultations/{id}/delete")
    public String delete(@PathVariable Long id, @RequestParam String adminPassword,
                         Principal principal, RedirectAttributes redirectAttributes) {
        try {
            reauthenticationService.verify(principal, adminPassword);
            consultationService.delete(id);
            redirectAttributes.addFlashAttribute("message", "상담 신청 내역이 삭제되었습니다.");
        } catch (IllegalArgumentException e) {
            redirectAttributes.addFlashAttribute("error", e.getMessage());
        }
        return "redirect:/admin/consultations";
    }
}
