package com.example.clinic.controller;

import com.example.clinic.domain.QnaPost;
import com.example.clinic.service.QnaService;
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

    public AdminQnaController(QnaService qnaService) {
        this.qnaService = qnaService;
    }

    @GetMapping("/admin/qna/{id}")
    public String detail(@PathVariable Long id, Model model) {
        QnaPost post = qnaService.findByIdWithAttachments(id);
        model.addAttribute("post", post);
        return "admin/qna-detail";
    }

    @PostMapping("/admin/qna/{id}/answer")
    public String answer(@PathVariable Long id, @RequestParam String answer, RedirectAttributes redirectAttributes) {
        qnaService.answer(id, answer);
        redirectAttributes.addFlashAttribute("message", "답변이 등록되었습니다.");
        return "redirect:/admin/qna/" + id;
    }

    @PostMapping("/admin/qna/{id}/delete")
    public String delete(@PathVariable Long id, RedirectAttributes redirectAttributes) {
        qnaService.delete(id);
        redirectAttributes.addFlashAttribute("message", "상담 글이 삭제되었습니다.");
        return "redirect:/admin";
    }
}
