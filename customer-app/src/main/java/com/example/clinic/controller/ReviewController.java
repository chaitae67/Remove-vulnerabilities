package com.example.clinic.controller;

import java.security.Principal;
import java.nio.charset.StandardCharsets;

import org.springframework.security.access.AccessDeniedException;
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
import com.example.clinic.util.PrivacyMasker;

@Controller
public class ReviewController {

    private final ReviewService reviewService;
    private final UserService userService;
    private final ProcedureService procedureService;

    public ReviewController(
        ReviewService reviewService,
        UserService userService,
        ProcedureService procedureService
    ) {
        this.reviewService = reviewService;
        this.userService = userService;
        this.procedureService = procedureService;
    }

    // IN-11: 후기의 소유자(작성자) 또는 관리자만 수정/삭제할 수 있는지 검증한다.
    private void assertCanManage(Review review, Principal principal) {
        AppUser viewer = principal == null ? null : userService.findByUsername(principal.getName());
        boolean admin = viewer != null && viewer.getRole() == Role.ADMIN;
        boolean owner = viewer != null && review.getWriter() != null
            && review.getWriter().getUsername().equals(viewer.getUsername());
        if (!admin && !owner) {
            throw new AccessDeniedException("후기를 수정하거나 삭제할 권한이 없습니다.");
        }
    }

    @GetMapping("/reviews")
    public String list(Model model) {
        model.addAttribute("reviews", reviewService.findAll());
        return "reviews/list";
    }

    @GetMapping("/reviews/new")
    public String createForm(Principal principal, Model model) {
        // 작성 폼은 로그인한 회원의 id를 필요로 하므로, 비로그인 상태면 로그인 화면으로 보낸다.
        if (principal == null) {
            return "redirect:/login?redirect=/reviews/new";
        }
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
        // CI-01: 사용자 입력을 템플릿으로 평가(SSTI)하지 않고 입력 원문을 전달한다.
        model.addAttribute("products", procedureService.findActiveProcedures());
        model.addAttribute("formTitle", title);
        model.addAttribute("formContent", content);
        model.addAttribute("formRating", rating);
        model.addAttribute("formProcedureProductId", procedureProductId);
        model.addAttribute("preview", content);
        return "reviews/form";
    }

    // IN-11/PV-13: 작성자는 요청 파라미터(writerId)가 아니라 인증된 세션에서 결정한다.
    @PostMapping("/reviews")
    public String create(
        @RequestParam String title,
        @RequestParam String content,
        @RequestParam int rating,
        @RequestParam(required = false) Long procedureProductId,
        @RequestParam(required = false) MultipartFile[] photos,
        Principal principal,
        RedirectAttributes redirectAttributes
    ) {
        AppUser writer = userService.findByUsername(principal.getName());
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
        model.addAttribute("maskedWriter", owner ? review.getWriter().getName() : PrivacyMasker.name(review.getWriter().getName()));
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
            .contentType(MediaType.APPLICATION_OCTET_STREAM)
            .header("X-Content-Type-Options", "nosniff")
            .header(HttpHeaders.CONTENT_DISPOSITION, ContentDisposition.attachment()
                .filename(attachment.getOriginalFilename(), StandardCharsets.UTF_8)
                .build().toString())
            .body(resource);
    }

    @GetMapping("/reviews/{id}/edit")
    public String editForm(@PathVariable Long id, Principal principal, Model model) {
        Review review = reviewService.findById(id);
        assertCanManage(review, principal);
        model.addAttribute("review", review);
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
        Principal principal,
        RedirectAttributes redirectAttributes
    ) {
        assertCanManage(reviewService.findById(id), principal);
        reviewService.update(id, title, content, rating, procedureProductId, photos);
        redirectAttributes.addFlashAttribute("message", "후기가 수정되었습니다.");
        return "redirect:/reviews/" + id;
    }

    @PostMapping("/reviews/{id}/delete")
    public String delete(@PathVariable Long id, Principal principal, RedirectAttributes redirectAttributes) {
        assertCanManage(reviewService.findById(id), principal);
        reviewService.delete(id);
        redirectAttributes.addFlashAttribute("message", "후기가 삭제되었습니다.");
        return "redirect:/reviews";
    }
}
