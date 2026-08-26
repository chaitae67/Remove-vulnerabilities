package com.example.clinic.service;

import com.example.clinic.domain.QuickConsultation;
import com.example.clinic.repository.QuickConsultationRepository;
import java.util.List;
import java.time.LocalDate;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

@Service
public class QuickConsultationService {

    private final QuickConsultationRepository consultationRepository;

    public QuickConsultationService(QuickConsultationRepository consultationRepository) {
        this.consultationRepository = consultationRepository;
    }

    @Transactional
    public QuickConsultation create(String name, String phone, String area, String preferredContact, LocalDate preferredDate, String message, boolean privacyAgreed) {
        if (!privacyAgreed) {
            throw new IllegalArgumentException("개인정보 수집 및 이용에 동의해 주세요.");
        }
        if (preferredDate == null || preferredDate.isBefore(LocalDate.now())) {
            throw new IllegalArgumentException("희망 날짜를 오늘 이후로 선택해 주세요.");
        }
        QuickConsultation consultation = new QuickConsultation();
        consultation.setName(name);
        consultation.setPhone(phone);
        consultation.setArea(area);
        consultation.setPreferredContact(preferredContact);
        consultation.setPreferredDate(preferredDate);
        consultation.setMessage(message);
        consultation.setPrivacyAgreed(true);
        return consultationRepository.save(consultation);
    }

    public List<QuickConsultation> findRecentConsultations() {
        return consultationRepository.findTop10ByOrderByCreatedAtDesc();
    }
}
