package com.example.clinic.controller;

import com.example.clinic.domain.AppUser;
import com.example.clinic.domain.Notice;
import com.example.clinic.service.AdminReauthenticationService;
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
public class AdminNoticeController {

    private final NoticeService noticeService;
    private final UserService userService;
    private final AdminReauthenticationService reauthenticationService;

    public AdminNoticeController(NoticeService noticeService, UserService userService,
                                 AdminReauthenticationService reauthenticationService) {
        this.noticeService = noticeService;
        this.userService = userService;
        this.reauthenticationService = reauthenticationService;
    }

    @GetMapping("/admin/notices")
    public String list(Model model) {
        model.addAttribute("notices", noticeService.findAll());
        return "admin/notices";
    }

    @GetMapping("/admin/notices/new")
    public String createForm(Model model) {
        model.addAttribute("formMode", "create");
        return "admin/notice-form";
    }

    @PostMapping("/admin/notices")
    public String create(@RequestParam String title,
                         @RequestParam String content,
                         @RequestParam(required = false) String imageUrl,
                         @RequestParam String adminPassword,
                         Principal principal,
                         RedirectAttributes redirectAttributes) {
        try {
            reauthenticationService.verify(principal, adminPassword);
            AppUser author = userService.findByUsername(principal.getName());
            Notice notice = noticeService.create(title, content, imageUrl, author);
            redirectAttributes.addFlashAttribute("message", "공지사항이 등록되었습니다.");
            return "redirect:/admin/notices/" + notice.getId();
        } catch (IllegalArgumentException exception) {
            redirectAttributes.addFlashAttribute("error", exception.getMessage());
            return "redirect:/admin/notices/new";
        }
    }

    @GetMapping("/admin/notices/{id}")
    public String detail(@PathVariable Long id, Model model) {
        model.addAttribute("notice", noticeService.findById(id));
        model.addAttribute("formMode", "edit");
        return "admin/notice-form";
    }

    @PostMapping("/admin/notices/{id}")
    public String update(@PathVariable Long id,
                         @RequestParam String title,
                         @RequestParam String content,
                         @RequestParam(required = false) String imageUrl,
                         @RequestParam String adminPassword,
                         Principal principal,
                         RedirectAttributes redirectAttributes) {
        try {
            reauthenticationService.verify(principal, adminPassword);
            noticeService.update(id, title, content, imageUrl);
            redirectAttributes.addFlashAttribute("message", "공지사항이 수정되었습니다.");
        } catch (IllegalArgumentException exception) {
            redirectAttributes.addFlashAttribute("error", exception.getMessage());
        }
        return "redirect:/admin/notices/" + id;
    }

    @PostMapping("/admin/notices/{id}/delete")
    public String delete(@PathVariable Long id,
                         @RequestParam String adminPassword,
                         Principal principal,
                         RedirectAttributes redirectAttributes) {
        try {
            reauthenticationService.verify(principal, adminPassword);
            noticeService.delete(id);
            redirectAttributes.addFlashAttribute("message", "공지사항이 삭제되었습니다.");
            return "redirect:/admin/notices";
        } catch (IllegalArgumentException exception) {
            redirectAttributes.addFlashAttribute("error", exception.getMessage());
            return "redirect:/admin/notices/" + id;
        }
    }
}
