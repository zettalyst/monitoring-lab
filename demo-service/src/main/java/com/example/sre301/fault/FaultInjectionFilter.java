package com.example.sre301.fault;

import java.io.IOException;

import jakarta.servlet.FilterChain;
import jakarta.servlet.ServletException;
import jakarta.servlet.http.HttpServletRequest;
import jakarta.servlet.http.HttpServletResponse;
import org.springframework.stereotype.Component;
import org.springframework.web.filter.OncePerRequestFilter;

@Component
class FaultInjectionFilter extends OncePerRequestFilter {

    private final FaultState faultState;

    FaultInjectionFilter(FaultState faultState) {
        this.faultState = faultState;
    }

    @Override
    protected void doFilterInternal(HttpServletRequest request, HttpServletResponse response, FilterChain filterChain)
        throws ServletException, IOException {
        if (request.getRequestURI().startsWith("/api/")) {
            String syntheticError = faultState.beforeApiRequest();
            if (syntheticError != null) {
                response.sendError(HttpServletResponse.SC_SERVICE_UNAVAILABLE, syntheticError);
                return;
            }
        }

        filterChain.doFilter(request, response);
    }
}
