package com.example.clinic.controller;

import java.security.Principal;
import java.nio.charset.StandardCharsets;

import org.springframework.core.io.Resource;
import org.springframework.http.HttpHeaders;
import org.springframework.http.ContentDisposition;
import org.springframework.http.MediaType;
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
import com.example.clinic.domain.QnaAttachment;
import com.example.clinic.domain.Role;
import com.example.clinic.service.QnaService;
import com.example.clinic.service.UserService;
import com.example.clinic.util.PrivacyMasker;

@Controller
public class QnaController {

    private final QnaService qnaService;
    private final UserService userService;

    public QnaController(
        QnaService qnaService,
        UserService userService
    ) {
        this.qnaService = qnaService;
        this.userService = userService;
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
        // CI-01: 사용자 입력을 템플릿으로 평가(SSTI)하지 않고, 입력 원문을 그대로 전달한다.
        // 화면 출력 시 FreeMarker HTML 자동 이스케이프로 XSS도 함께 차단된다.
        model.addAttribute("formTitle", title);
        model.addAttribute("formContent", content);
        model.addAttribute("formPhone", phone);
        model.addAttribute("formPrivatePost", privatePost);
        model.addAttribute("preview", content);
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
        model.addAttribute("maskedWriter", owner ? post.getWriter().getName() : PrivacyMasker.name(post.getWriter().getName()));
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

    @GetMapping("/qna/{postId}/attachments/{attachmentId}")
    public ResponseEntity<Resource> download(
        @PathVariable Long postId,
        @PathVariable Long attachmentId,
        Principal principal
    ) {
        QnaPost post = qnaService.findByIdWithAttachments(postId);
        AppUser viewer = principal == null ? null : userService.findByUsername(principal.getName());
        boolean admin = viewer != null && viewer.getRole() == Role.ADMIN;
        boolean owner = viewer != null && post.getWriter().getUsername().equals(viewer.getUsername());
        if (post.isPrivatePost() && !admin && !owner) {
            throw new AccessDeniedException("첨부파일을 내려받을 권한이 없습니다.");
        }
        QnaAttachment attachment = qnaService.findAttachment(post, attachmentId);
        Resource resource = qnaService.loadAttachment(attachment.getStoredFilename());
        return ResponseEntity.ok()
            .contentType(MediaType.APPLICATION_OCTET_STREAM)
            .header("X-Content-Type-Options", "nosniff")
            .header(HttpHeaders.CONTENT_DISPOSITION, ContentDisposition.attachment()
                .filename(attachment.getOriginalFilename(), StandardCharsets.UTF_8)
                .build().toString())
            .body(resource);
    }

}
