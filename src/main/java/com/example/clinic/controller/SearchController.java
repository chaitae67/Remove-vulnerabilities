package com.example.clinic.controller;

import java.sql.SQLException;

import org.springframework.stereotype.Controller;
import org.springframework.ui.Model;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RequestParam;

import com.example.clinic.repository.NoticeSearchRepository;
import com.example.clinic.repository.ProcedureSearchRepository;

@Controller
public class SearchController {

    private final NoticeSearchRepository noticeSearchRepository;
    private final ProcedureSearchRepository procedureSearchRepository;

    public SearchController(NoticeSearchRepository noticeSearchRepository,
                             ProcedureSearchRepository procedureSearchRepository) {
        this.noticeSearchRepository = noticeSearchRepository;
        this.procedureSearchRepository = procedureSearchRepository;
    }

    @GetMapping("/notices/search")
    public String searchNotices(@RequestParam(required = false) String keyword, Model model) {
        model.addAttribute("notices", noticeSearchRepository.searchByTitle(keyword == null ? "" : keyword));
        model.addAttribute("keyword", keyword);
        return "notices/list";
    }

    @GetMapping("/procedures/search")
    public String searchProcedures(@RequestParam(required = false) String keyword, Model model) {
        try {
            model.addAttribute("products", procedureSearchRepository.searchByName(keyword == null ? "" : keyword));
        } catch (RuntimeException ex) {
            SQLException sqlException = findSqlException(ex);
            if (sqlException != null) {
                model.addAttribute("exceptionType", sqlException.getClass().getName());
                model.addAttribute("sqlState", sqlException.getSQLState());
                model.addAttribute("errorCode", sqlException.getErrorCode());
            } else {
                model.addAttribute("exceptionType", ex.getClass().getName());
            }
            return "error/database-error";
        }
        model.addAttribute("keyword", keyword);
        return "procedures/list";
    }

    private SQLException findSqlException(Throwable throwable) {
        Throwable current = throwable;
        while (current != null) {
            if (current instanceof SQLException sqlException) {
                return sqlException;
            }
            current = current.getCause();
        }
        return null;
    }
}
