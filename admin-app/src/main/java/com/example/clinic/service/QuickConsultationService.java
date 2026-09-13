package com.example.clinic.service;

import com.example.clinic.domain.QuickConsultation;
import com.example.clinic.repository.QuickConsultationRepository;
import com.example.clinic.repository.QuickConsultationSearchRepository;
import java.util.List;
import java.time.LocalDate;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

@Service
public class QuickConsultationService {

    private final QuickConsultationRepository consultationRepository;
    private final QuickConsultationSearchRepository consultationSearchRepository;

    public QuickConsultationService(
        QuickConsultationRepository consultationRepository,
        QuickConsultationSearchRepository consultationSearchRepository
    ) {
        this.consultationRepository = consultationRepository;
        this.consultationSearchRepository = consultationSearchRepository;
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

    public List<QuickConsultation> findAllConsultations() {
        return consultationRepository.findAllByOrderByCreatedAtDesc();
    }

    public List<QuickConsultation> search(String keyword) {
        if (keyword == null || keyword.isBlank()) {
            return findAllConsultations();
        }
        return consultationSearchRepository.search(keyword.trim());
    }

    public QuickConsultation findById(Long id) {
        return consultationRepository.findById(id)
            .orElseThrow(() -> new IllegalArgumentException("상담 신청 내역을 찾을 수 없습니다."));
    }

    @Transactional
    public QuickConsultation update(
        Long id,
        String name,
        String phone,
        String area,
        String preferredContact,
        LocalDate preferredDate,
        String message,
        String adminNote
    ) {
        QuickConsultation consultation = findById(id);
        if (name == null || name.isBlank()) {
            throw new IllegalArgumentException("신청자 이름을 입력해 주세요.");
        }
        if (phone == null || phone.isBlank()) {
            throw new IllegalArgumentException("연락처를 입력해 주세요.");
        }
        consultation.setName(name.trim());
        consultation.setPhone(phone.trim());
        consultation.setArea(area == null ? "" : area.trim());
        consultation.setPreferredContact(preferredContact == null ? "" : preferredContact.trim());
        consultation.setPreferredDate(preferredDate);
        consultation.setMessage(message);
        consultation.setAdminNote(adminNote);
        return consultationRepository.save(consultation);
    }

    @Transactional
    public void delete(Long id) {
        consultationRepository.delete(findById(id));
    }
}
