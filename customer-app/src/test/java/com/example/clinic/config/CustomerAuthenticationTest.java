package com.example.clinic.config;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.when;

import com.example.clinic.domain.AppUser;
import com.example.clinic.domain.Role;
import com.example.clinic.repository.AppUserRepository;
import java.util.Optional;
import org.junit.jupiter.api.Test;
import org.springframework.security.core.userdetails.UserDetails;
import org.springframework.security.core.userdetails.UserDetailsService;
import org.springframework.security.core.userdetails.UsernameNotFoundException;

class CustomerAuthenticationTest {

    @Test
    void rejectsAdministratorAccountOnCustomerApplication() {
        AppUserRepository repository = mock(AppUserRepository.class);
        when(repository.findByUsername("admin")).thenReturn(Optional.of(user("admin", Role.ADMIN)));

        UserDetailsService service = new SecurityConfig(false).userDetailsService(repository);

        assertThatThrownBy(() -> service.loadUserByUsername("admin"))
            .isInstanceOf(UsernameNotFoundException.class);
    }

    @Test
    void acceptsCustomerAccountOnCustomerApplication() {
        AppUserRepository repository = mock(AppUserRepository.class);
        when(repository.findByUsername("customer")).thenReturn(Optional.of(user("customer", Role.USER)));

        UserDetailsService service = new SecurityConfig(false).userDetailsService(repository);
        UserDetails details = service.loadUserByUsername("customer");

        assertThat(details.getUsername()).isEqualTo("customer");
        assertThat(details.getAuthorities())
            .extracting("authority")
            .containsExactly("ROLE_USER");
    }

    private AppUser user(String username, Role role) {
        AppUser user = new AppUser();
        user.setUsername(username);
        user.setPassword("{noop}test-password");
        user.setRole(role);
        return user;
    }
}
