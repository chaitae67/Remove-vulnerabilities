package com.example.clinic.config;

import com.example.clinic.domain.AppUser;
import com.example.clinic.domain.Coupon;
import com.example.clinic.domain.Notice;
import com.example.clinic.domain.ProcedureProduct;
import com.example.clinic.domain.QnaPost;
import com.example.clinic.domain.Review;
import com.example.clinic.domain.Role;
import com.example.clinic.repository.AppUserRepository;
import com.example.clinic.repository.CouponRepository;
import com.example.clinic.repository.NoticeRepository;
import com.example.clinic.repository.ProcedureProductRepository;
import com.example.clinic.repository.QnaPostRepository;
import com.example.clinic.repository.ReviewRepository;
import java.math.BigDecimal;
import org.springframework.boot.CommandLineRunner;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import org.springframework.security.crypto.password.PasswordEncoder;

@Configuration
public class DataSeeder {

    @Bean
    CommandLineRunner seedData(
        AppUserRepository userRepository,
        ProcedureProductRepository procedureRepository,
        NoticeRepository noticeRepository,
        QnaPostRepository qnaPostRepository,
        ReviewRepository reviewRepository,
        PasswordEncoder passwordEncoder,
        CouponRepository couponRepository
    ) {
        return args -> {
            AppUser admin = userRepository.findByUsername("admin").orElseGet(() -> {
                AppUser user = new AppUser();
                user.setUsername("admin");
                user.setPassword(passwordEncoder.encode("admin1234"));
                user.setName("관리자");
                user.setEmail("admin@clinic.local");
                user.setPhone("02-0000-0000");
                user.setRole(Role.ADMIN);
                user.setPointBalance(10000);
                return userRepository.save(user);
            });

            AppUser member = userRepository.findByUsername("user").orElseGet(() -> {
                AppUser user = new AppUser();
                user.setUsername("user");
                user.setPassword(passwordEncoder.encode("user1234"));
                user.setName("테스트회원");
                user.setEmail("user@clinic.local");
                user.setPhone("010-1234-5678");
                user.setRole(Role.USER);
                user.setPointBalance(5000);
                return userRepository.save(user);
            });

            if (couponRepository.count() == 0) {
                Coupon welcome = new Coupon();
                welcome.setCode("WELCOME10000");
                welcome.setName("신규 회원 1만원 할인");
                welcome.setDiscountAmount(10000);
                welcome.setExpiresAt(java.time.LocalDate.now().plusYears(1));
                couponRepository.save(welcome);
            }

            if (procedureRepository.count() == 0) {
                procedureRepository.save(procedure("바디라인 컨설팅 패키지", "지방흡입", "부위별 라인 분석과 수술 전 검사를 포함한 기본 상담 패키지", "상담, 체형 분석, 수술 가능성 안내를 묶은 입문 패키지입니다. 실제 수술 여부와 비용은 의료진 상담 후 확정됩니다.", 50000));
                procedureRepository.save(procedure("얼굴 윤곽 상담 패키지", "윤곽/리프팅", "얼굴 비율 진단과 맞춤 시술 제안을 제공하는 상담 패키지", "정면/측면 밸런스를 확인하고 비수술/수술 선택지를 안내합니다.", 70000));
                procedureRepository.save(procedure("수술 후 케어 패키지", "사후관리", "붓기, 흉터, 회복 경과 확인을 위한 관리 예약 상품", "수술 후 회복 상태를 체크하고 개인별 케어 일정을 제안합니다.", 120000));
            }

            if (noticeRepository.count() == 0) {
                Notice notice = new Notice();
                notice.setTitle("8월 진료 일정 안내");
                notice.setContent("광복절 및 병원 내부 교육 일정에 따라 일부 진료 시간이 조정됩니다. 예약 전 전화 확인을 부탁드립니다.");
                notice.setAuthor(admin);
                noticeRepository.save(notice);

                Notice safety = new Notice();
                safety.setTitle("상담 전 안내사항");
                safety.setContent("온라인 상담은 참고용이며 정확한 진단과 치료 계획은 내원 후 의료진 상담을 통해 결정됩니다.");
                safety.setAuthor(admin);
                noticeRepository.save(safety);
            }

            if (qnaPostRepository.count() == 0) {
                QnaPost post = new QnaPost();
                post.setTitle("허벅지 라인 상담 가능할까요?");
                post.setContent("회복 기간과 대략적인 상담 절차가 궁금합니다.");
                post.setPhone(member.getPhone());
                post.setPrivatePost(false);
                post.setWriter(member);
                post.setAnswered(true);
                post.setAnswer("개인 상태에 따라 다르므로 사진 상담 또는 내원 상담을 권장드립니다. 기본 회복 안내는 상담 시 자세히 설명드릴게요.");
                qnaPostRepository.save(post);
            }

            if (reviewRepository.count() == 0) {
                ProcedureProduct featured = procedureRepository.findByActiveTrueOrderByIdAsc()
                    .stream().findFirst().orElse(null);

                Review review = new Review();
                review.setTitle("상담부터 관리까지 꼼꼼하게 챙겨주셨어요");
                review.setContent("체형 분석부터 회복 케어 일정까지 자세히 안내해 주셔서 만족스러웠습니다.");
                review.setRating(5);
                review.setWriter(member);
                review.setProcedureProduct(featured);
                reviewRepository.save(review);
            }
        };
    }

    private ProcedureProduct procedure(String name, String category, String summary, String description, int price) {
        ProcedureProduct product = new ProcedureProduct();
        product.setName(name);
        product.setCategory(category);
        product.setSummary(summary);
        product.setDescription(description);
        product.setPrice(BigDecimal.valueOf(price));
        return product;
    }
}
