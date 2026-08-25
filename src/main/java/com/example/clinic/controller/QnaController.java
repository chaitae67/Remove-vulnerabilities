package com.example.clinic.controller;

import java.security.Principal;
import java.util.HashMap;
import java.util.Map;

import org.springframework.core.io.Resource;
import org.springframework.http.HttpHeaders;
import org.springframework.http.ResponseEntity;
import org.springframework.security.access.AccessDeniedException;
import org.springframework.stereotype.Controller;
import org.springframework.ui.Model;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.multipart.MultipartFile;
import org.springframework.web.servlet.mvc.support.RedirectAttributes;

import com.example.clinic.domain.AppUser;
import com.example.clinic.domain.QnaPost;
import com.example.clinic.domain.Role;
import com.example.clinic.service.QnaService;
import com.example.clinic.service.UserService;
import com.example.clinic.service.VulnerableTemplatePreviewService;

@Controller
public class QnaController {

    private final QnaService qnaService;
    private final UserService userService;
    private final VulnerableTemplatePreviewService templatePreviewService;

    public QnaController(
        QnaService qnaService,
        UserService userService,
        VulnerableTemplatePreviewService templatePreviewService
    ) {
        this.qnaService = qnaService;
        this.userService = userService;
        this.templatePreviewService = templatePreviewService;
    }

    @GetMapping("/qna")
    public String list(Model model) {
        model.addAttribute("posts", qnaService.findAll());
        return "qna/list";
    }

    @GetMapping("/qna/new")
    public String createForm() {
        return "qna/form";
    }

    @PostMapping("/qna/preview")
    public String preview(
        @RequestParam String title,
        @RequestParam String content,
        @RequestParam(required = false) String phone,
        @RequestParam(defaultValue = "false") boolean privatePost,
        Principal principal,
        Model model
    ) {
        AppUser viewer = userService.findByUsername(principal.getName());
        Map<String, Object> variables = new HashMap<>();
        variables.put("authorName", viewer.getName());
        variables.put("title", title);
        variables.put("phone", phone == null ? "" : phone);

        model.addAttribute("formTitle", title);
        model.addAttribute("formContent", content);
        model.addAttribute("formPhone", phone);
        model.addAttribute("formPrivatePost", privatePost);
        try {
            model.addAttribute("preview", templatePreviewService.render(content, variables));
        } catch (Exception exception) {
            model.addAttribute("previewError", exception.getMessage());
        }
        return "qna/form";
    }

    @PostMapping("/qna")
    public String create(
        @RequestParam String title,
        @RequestParam String content,
        @RequestParam(required = false) String phone,
        @RequestParam(defaultValue = "false") boolean privatePost,
        @RequestParam(required = false) MultipartFile[] files,
        Principal principal,
        RedirectAttributes redirectAttributes
    ) {
        AppUser writer = userService.findByUsername(principal.getName());
        QnaPost post = qnaService.create(title, content, phone, privatePost, writer, files);
        redirectAttributes.addFlashAttribute("message", "상담 글이 등록되었습니다.");
        return "redirect:/qna/" + post.getId();
    }

    @GetMapping("/qna/{id}")
    public String detail(@PathVariable Long id, Principal principal, Model model) {
        QnaPost post = qnaService.findByIdWithAttachments(id);
        AppUser viewer = principal == null ? null : userService.findByUsername(principal.getName());
        boolean admin = viewer != null && viewer.getRole() == Role.ADMIN;
        boolean owner = viewer != null && post.getWriter().getUsername().equals(viewer.getUsername());
        model.addAttribute("post", post);
        model.addAttribute("canReadPrivate", !post.isPrivatePost() || admin || owner);
        model.addAttribute("canAnswer", admin);
        model.addAttribute("canManage", admin || owner);
        return "qna/detail";
    }

    @PostMapping("/qna/{id}/delete")
    public String delete(@PathVariable Long id, Principal principal, RedirectAttributes redirectAttributes) {
        QnaPost post = qnaService.findByIdWithAttachments(id);
        AppUser viewer = principal == null ? null : userService.findByUsername(principal.getName());
        boolean admin = viewer != null && viewer.getRole() == Role.ADMIN;
        boolean owner = viewer != null && post.getWriter().getUsername().equals(viewer.getUsername());
        if (!admin && !owner) {
            throw new AccessDeniedException("삭제 권한이 없습니다.");
        }
        qnaService.delete(id);
        redirectAttributes.addFlashAttribute("message", "상담 글이 삭제되었습니다.");
        return "redirect:/qna";
    }

    @PostMapping("/qna/{id}/answer")
    public String answer(@PathVariable Long id, @RequestParam String answer, RedirectAttributes redirectAttributes) {
        qnaService.answer(id, answer);
        redirectAttributes.addFlashAttribute("message", "답변이 등록되었습니다.");
        return "redirect:/qna/" + id;
    }

    @GetMapping("/qna/download")
    public ResponseEntity<Resource> download(@RequestParam String filename) {
        Resource resource = qnaService.loadAttachment(filename);
        return ResponseEntity.ok()
            .header(HttpHeaders.CONTENT_DISPOSITION, "attachment; filename=\"" + resource.getFilename() + "\"")
            .body(resource);
    }
}
