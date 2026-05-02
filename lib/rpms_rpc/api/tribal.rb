# frozen_string_literal: true

module RpmsRpc
  module Tribal
    extend self

    def enrollment(dfn)
      DataMapper.tribal_enrollment.fetch_one(dfn.to_s)
    end

    def validate(enrollment_number)
      DataMapper.tribal_validation.fetch_one(enrollment_number.to_s)
    end

    def eligibility(dfn)
      DataMapper.enrollment_eligibility.fetch_one(dfn.to_s) || { active: false, eligible_for_ihs: false }
    end

    def service_unit(dfn)
      DataMapper.service_unit.fetch_one(dfn.to_s)
    end

    def tribe_info(code)
      DataMapper.tribe_info.fetch_one(code.to_s)
    end
  end
end
