package com.example.clinic.controller;

import com.example.clinic.domain.QnaPost;
import com.example.clinic.service.QnaService;
import com.example.clinic.util.PrivacyMasker;
import java.time.LocalDateTime;
import com.example.clinic.service.AdminReauthenticationService;
import java.security.Principal;
import org.springframework.stereotype.Controller;
import org.springframework.ui.Model;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.servlet.mvc.support.RedirectAttributes;

@Controller
public class AdminQnaController {

    private final QnaService qnaService;
    private final AdminReauthenticationService reauthenticationService;

    public AdminQnaController(QnaService qnaService, AdminReauthenticationService reauthenticationService) {
        this.qnaService = qnaService;
        this.reauthenticationService = reauthenticationService;
    }

    @GetMapping("/admin/qna")
    public String list(Model model) {
        model.addAttribute("posts", qnaService.findAll().stream().map(QnaListItem::from).toList());
        return "admin/qna";
    }

    public static final class QnaListItem {
        private final Long id;
        private final String title;
        private final String writerName;
        private final boolean privatePost;
        private final boolean answered;
        private final LocalDateTime createdAt;

        private QnaListItem(Long id, String title, String writerName, boolean privatePost,
                            boolean answered, LocalDateTime createdAt) {
            this.id = id;
            this.title = title;
            this.writerName = writerName;
            this.privatePost = privatePost;
            this.answered = answered;
            this.createdAt = createdAt;
        }

        static QnaListItem from(QnaPost post) {
            return new QnaListItem(post.getId(), post.getTitle(), PrivacyMasker.name(post.getWriter().getName()),
                post.isPrivatePost(), post.isAnswered(), post.getCreatedAt());
        }

        public Long getId() { return id; }
        public String getTitle() { return title; }
        public String getWriterName() { return writerName; }
        public boolean isPrivatePost() { return privatePost; }
        public boolean isAnswered() { return answered; }
        public LocalDateTime getCreatedAt() { return createdAt; }
    }

    @GetMapping("/admin/qna/{id}")
    public String detail(@PathVariable Long id, Model model) {
        QnaPost post = qnaService.findByIdWithAttachments(id);
        model.addAttribute("post", post);
        return "admin/qna-detail";
    }

    @PostMapping("/admin/qna/{id}/answer")
    public String answer(@PathVariable Long id, @RequestParam String answer,
                         @RequestParam String adminPassword, Principal principal,
                         RedirectAttributes redirectAttributes) {
        try {
            reauthenticationService.verify(principal, adminPassword);
            qnaService.answer(id, answer);
            redirectAttributes.addFlashAttribute("message", "답변이 등록되었습니다.");
        } catch (IllegalArgumentException exception) {
            redirectAttributes.addFlashAttribute("error", exception.getMessage());
        }
        return "redirect:/admin/qna/" + id;
    }

    @PostMapping("/admin/qna/{id}/delete")
    public String delete(@PathVariable Long id, @RequestParam String adminPassword,
                         Principal principal, RedirectAttributes redirectAttributes) {
        try {
            reauthenticationService.verify(principal, adminPassword);
            qnaService.delete(id);
            redirectAttributes.addFlashAttribute("message", "상담 글이 삭제되었습니다.");
        } catch (IllegalArgumentException exception) {
            redirectAttributes.addFlashAttribute("error", exception.getMessage());
            return "redirect:/admin/qna/" + id;
        }
        return "redirect:/admin/qna";
    }
}
