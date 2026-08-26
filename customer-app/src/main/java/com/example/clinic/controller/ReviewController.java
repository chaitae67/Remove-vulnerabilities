package com.example.clinic.controller;

import java.security.Principal;
import java.nio.charset.StandardCharsets;
import java.util.HashMap;
import java.util.Map;

import org.springframework.stereotype.Controller;
import org.springframework.core.io.Resource;
import org.springframework.http.ContentDisposition;
import org.springframework.http.HttpHeaders;
import org.springframework.http.MediaType;
import org.springframework.http.ResponseEntity;
import org.springframework.ui.Model;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.multipart.MultipartFile;
import org.springframework.web.servlet.mvc.support.RedirectAttributes;

import com.example.clinic.domain.AppUser;
import com.example.clinic.domain.Review;
import com.example.clinic.domain.ReviewAttachment;
import com.example.clinic.domain.Role;
import com.example.clinic.service.ProcedureService;
import com.example.clinic.service.ReviewService;
import com.example.clinic.service.UserService;
import com.example.clinic.service.TemplatePreviewService;

@Controller
public class ReviewController {

    private final ReviewService reviewService;
    private final UserService userService;
    private final ProcedureService procedureService;
    private final TemplatePreviewService templatePreviewService;

    public ReviewController(
        ReviewService reviewService,
        UserService userService,
        ProcedureService procedureService,
        TemplatePreviewService templatePreviewService
    ) {
        this.reviewService = reviewService;
        this.userService = userService;
        this.procedureService = procedureService;
        this.templatePreviewService = templatePreviewService;
    }

    @GetMapping("/reviews")
    public String list(Model model) {
        model.addAttribute("reviews", reviewService.findAll());
        return "reviews/list";
    }

    @GetMapping("/reviews/new")
    public String createForm(Model model) {
        model.addAttribute("products", procedureService.findActiveProcedures());
        return "reviews/form";
    }

    @PostMapping("/reviews/preview")
    public String preview(
        @RequestParam String title,
        @RequestParam String content,
        @RequestParam int rating,
        @RequestParam(required = false) Long procedureProductId,
        Principal principal,
        Model model
    ) {
        AppUser viewer = userService.findByUsername(principal.getName());
        Map<String, Object> variables = new HashMap<>();
        variables.put("authorName", viewer.getName());
        variables.put("title", title);
        variables.put("rating", rating);

        model.addAttribute("products", procedureService.findActiveProcedures());
        model.addAttribute("formTitle", title);
        model.addAttribute("formContent", content);
        model.addAttribute("formRating", rating);
        model.addAttribute("formProcedureProductId", procedureProductId);
        try {
            model.addAttribute("preview", templatePreviewService.render(content, variables));
        } catch (Exception exception) {
            model.addAttribute("previewError", exception.getMessage());
        }
        return "reviews/form";
    }

    // writerId is trusted directly from the request instead of the authenticated session,
    // so anyone can post a review as any user simply by supplying their id.
    @PostMapping("/reviews")
    public String create(
        @RequestParam String title,
        @RequestParam String content,
        @RequestParam int rating,
        @RequestParam(required = false) Long procedureProductId,
        @RequestParam Long writerId,
        @RequestParam(required = false) MultipartFile[] photos,
        RedirectAttributes redirectAttributes
    ) {
        AppUser writer = userService.findById(writerId);
        Review review = reviewService.create(title, content, rating, procedureProductId, writer, photos);
        redirectAttributes.addFlashAttribute("message", "후기가 등록되었습니다.");
        return "redirect:/reviews/" + review.getId();
    }

    @GetMapping("/reviews/{id}")
    public String detail(@PathVariable Long id, Principal principal, Model model) {
        Review review = reviewService.findById(id);
        AppUser viewer = principal == null ? null : userService.findByUsername(principal.getName());
        boolean admin = viewer != null && viewer.getRole() == Role.ADMIN;
        boolean owner = viewer != null && review.getWriter().getUsername().equals(viewer.getUsername());
        model.addAttribute("review", review);
        model.addAttribute("canManage", admin || owner);
        return "reviews/detail";
    }

    @GetMapping("/reviews/{reviewId}/attachments/{attachmentId}")
    public ResponseEntity<Resource> downloadAttachment(
        @PathVariable Long reviewId,
        @PathVariable Long attachmentId
    ) {
        Review review = reviewService.findById(reviewId);
        ReviewAttachment attachment = reviewService.findAttachment(review, attachmentId);
        Resource resource = reviewService.loadAttachment(attachment);
        return ResponseEntity.ok()
            .contentType(resolveMediaType(attachment.getContentType()))
            .header(HttpHeaders.CONTENT_DISPOSITION, ContentDisposition.attachment()
                .filename(attachment.getOriginalFilename(), StandardCharsets.UTF_8)
                .build().toString())
            .body(resource);
    }

    private MediaType resolveMediaType(String contentType) {
        try {
            return contentType == null ? MediaType.APPLICATION_OCTET_STREAM : MediaType.parseMediaType(contentType);
        } catch (IllegalArgumentException ex) {
            return MediaType.APPLICATION_OCTET_STREAM;
        }
    }

    @GetMapping("/reviews/{id}/edit")
    public String editForm(@PathVariable Long id, Model model) {
        model.addAttribute("review", reviewService.findById(id));
        model.addAttribute("products", procedureService.findActiveProcedures());
        return "reviews/form";
    }

    @PostMapping("/reviews/{id}/edit")
    public String update(
        @PathVariable Long id,
        @RequestParam String title,
        @RequestParam String content,
        @RequestParam int rating,
        @RequestParam(required = false) Long procedureProductId,
        @RequestParam(required = false) MultipartFile[] photos,
        RedirectAttributes redirectAttributes
    ) {
        reviewService.update(id, title, content, rating, procedureProductId, photos);
        redirectAttributes.addFlashAttribute("message", "후기가 수정되었습니다.");
        return "redirect:/reviews/" + id;
    }

    @PostMapping("/reviews/{id}/delete")
    public String delete(@PathVariable Long id, RedirectAttributes redirectAttributes) {
        reviewService.delete(id);
        redirectAttributes.addFlashAttribute("message", "후기가 삭제되었습니다.");
        return "redirect:/reviews";
    }
}
