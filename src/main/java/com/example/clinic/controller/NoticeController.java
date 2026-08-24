package com.example.clinic.controller;

import com.example.clinic.domain.AppUser;
import com.example.clinic.service.NoticeService;
import com.example.clinic.service.UserService;
import java.security.Principal;
import org.springframework.stereotype.Controller;
import org.springframework.ui.Model;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.servlet.mvc.support.RedirectAttributes;

@Controller
public class NoticeController {

    private final NoticeService noticeService;
    private final UserService userService;

    public NoticeController(NoticeService noticeService, UserService userService) {
        this.noticeService = noticeService;
        this.userService = userService;
    }

    @GetMapping("/notices")
    public String list(Model model) {
        model.addAttribute("notices", noticeService.findAll());
        return "notices/list";
    }

    @GetMapping("/notices/{id}")
    public String detail(@PathVariable Long id, Model model) {
        model.addAttribute("notice", noticeService.findById(id));
        return "notices/detail";
    }

    @GetMapping("/notices/new")
    public String createForm() {
        return "notices/form";
    }

    @PostMapping("/notices")
    public String create(@RequestParam String title, @RequestParam String content, Principal principal, RedirectAttributes redirectAttributes) {
        AppUser author = userService.findByUsername(principal.getName());
        noticeService.create(title, content, author);
        redirectAttributes.addFlashAttribute("message", "공지사항이 등록되었습니다.");
        return "redirect:/notices";
    }

    @GetMapping("/notices/{id}/edit")
    public String editForm(@PathVariable Long id, Model model) {
        model.addAttribute("notice", noticeService.findById(id));
        return "notices/form";
    }

    @PostMapping("/notices/{id}/edit")
    public String update(@PathVariable Long id, @RequestParam String title, @RequestParam String content, RedirectAttributes redirectAttributes) {
        noticeService.update(id, title, content);
        redirectAttributes.addFlashAttribute("message", "공지사항이 수정되었습니다.");
        return "redirect:/notices/" + id;
    }

    @PostMapping("/notices/{id}/delete")
    public String delete(@PathVariable Long id, RedirectAttributes redirectAttributes) {
        noticeService.delete(id);
        redirectAttributes.addFlashAttribute("message", "공지사항이 삭제되었습니다.");
        return "redirect:/notices";
    }
}
