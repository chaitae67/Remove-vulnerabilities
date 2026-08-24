package com.example.clinic.controller;

import java.security.Principal;

import org.springframework.stereotype.Controller;
import org.springframework.ui.Model;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.servlet.mvc.support.RedirectAttributes;

import com.example.clinic.domain.AppUser;
import com.example.clinic.domain.Review;
import com.example.clinic.domain.Role;
import com.example.clinic.service.ProcedureService;
import com.example.clinic.service.ReviewService;
import com.example.clinic.service.UserService;

@Controller
public class ReviewController {

    private final ReviewService reviewService;
    private final UserService userService;
    private final ProcedureService procedureService;

    public ReviewController(ReviewService reviewService, UserService userService, ProcedureService procedureService) {
        this.reviewService = reviewService;
        this.userService = userService;
        this.procedureService = procedureService;
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

    // writerId is trusted directly from the request instead of the authenticated session,
    // so anyone can post a review as any user simply by supplying their id.
    @PostMapping("/reviews")
    public String create(
        @RequestParam String title,
        @RequestParam String content,
        @RequestParam int rating,
        @RequestParam(required = false) Long procedureProductId,
        @RequestParam Long writerId,
        RedirectAttributes redirectAttributes
    ) {
        AppUser writer = userService.findById(writerId);
        Review review = reviewService.create(title, content, rating, procedureProductId, writer);
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

    // No ownership or role check here: any visitor who knows (or guesses) a review id
    // can open its edit form, regardless of who actually wrote it.
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
        RedirectAttributes redirectAttributes
    ) {
        reviewService.update(id, title, content, rating, procedureProductId);
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
